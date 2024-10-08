#!/usr/bin/env python3
# vi: ft=python

# Copyright 2021 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This template is completed by `pkg_install` to create installation scripts,
# and will not function on its own.  See pkg/install.bzl for more details.

import argparse
import logging
import os
import shutil
import sys

from pkg.private import manifest

# Globals used for runfile path manipulation.
#
# These are necessary because runfiles are different when used as a part of
# `bazel build` and `bazel run`. # See also
# https://docs.bazel.build/versions/4.1.0/skylark/rules.html#tools-with-runfiles

# Bazel's documentation claims these are set when calling `bazel run`, but not other
# modes, like in `build` or `test`.  We'll see.
CALLED_FROM_BAZEL_RUN = bool(os.getenv("BUILD_WORKSPACE_DIRECTORY") and
                             os.getenv("BUILD_WORKING_DIRECTORY"))

WORKSPACE_NAME = "{WORKSPACE_NAME}"
# This seems to be set when running in `bazel build` or `bazel test`
# TODO(#382): This may not be the case in Windows.
RUNFILE_PREFIX = os.path.join(os.getenv("RUNFILES_DIR"), WORKSPACE_NAME) if os.getenv("RUNFILES_DIR") else None


# This is named "NativeInstaller" because it makes use of "native" python
# functionality for installing files that should be cross-platform.
#
# A variant on this might be an installer at least partially based on coreutils.
# Most notably, some filesystems on Linux (and maybe others) support
# copy-on-write functionality that are known to tools like cp(1) and install(1)
# but may not be in the available python runtime.
#
# See also https://bugs.python.org/issue37157.
class NativeInstaller(object):
    def __init__(self, default_user=None, default_group=None, destdir=None):
        self.default_user = default_user
        self.default_group = default_group
        self.destdir = destdir
        self.entries = []

    # Logger helper method, may not be necessary or desired
    def _subst_destdir(path, self):
        return path.replace(self.destdir, "$DESTDIR")

    def _chown_chmod(self, dest, mode, user, group):
        if mode:
            logging.info("CHMOD %s %s", mode, dest)
            os.chmod(dest, int(mode, 8))
        if user or group:
            # Ownership can only be changed by sufficiently
            # privileged users.
            # TODO(nacl): This does not support windows
            if hasattr(os, "getuid") and os.getuid() == 0:
                logging.info("CHOWN %s:%s %s", user, group, dest)
                shutil.chown(dest, user, group)

    def _do_file_copy(self, src, dest, mode, user, group):
        logging.info("COPY %s <- %s", dest, src)
        shutil.copyfile(src, dest)

    def _do_mkdir(self, dirname, mode, user, group):
        logging.info("MKDIR %s %s", mode, dirname)
        os.makedirs(dirname, int(mode, 8), exist_ok=True)

    def _do_symlink(self, src, dest, mode, user, group):
        logging.info("SYMLINK %s <- %s", dest, src)
        os.symlink(src, dest)

    def _maybe_make_unowned_dir(self, path):
        logging.info("MKDIR (unowned) %s", path)
        # TODO(nacl): consider default permissions here
        # TODO(nacl): consider default ownership here
        os.makedirs(path, 0o755, exist_ok=True)

    def _install_file(self, entry):
        self._maybe_make_unowned_dir(os.path.dirname(entry.dest))
        self._do_file_copy(entry.src, entry.dest, entry.mode, entry.user, entry.group)
        self._chown_chmod(entry.dest, entry.mode, entry.user, entry.group)

    def _install_directory(self, entry):
        self._maybe_make_unowned_dir(os.path.dirname(entry.dest))
        self._do_mkdir(entry.dest, entry.mode, entry.user, entry.group)
        self._chown_chmod(entry.dest, entry.mode, entry.user, entry.group)

    def _install_treeartifact(self, entry):
        logging.info("COPYTREE %s <- %s/**", entry.dest, entry.src)
        shutil.copytree(entry.src, entry.dest)
        self._chown_chmod(entry.dest, entry.mode, entry.user, entry.group)
        for root, dirs, files in os.walk(entry.dest):
            for dir in dirs:
                self._chown_chmod(os.path.join(root, dir), entry.mode, entry.user, entry.group)
            for file in files:
                self._chown_chmod(os.path.join(root, file), entry.mode, entry.user, entry.group)

    def _install_symlink(self, entry):
        self._maybe_make_unowned_dir(os.path.dirname(entry.dest))
        self._do_symlink(entry.src, entry.dest, entry.mode, entry.user, entry.group)
        logging.info("SYMLINK %s <- %s", entry.dest, entry.src)
        logging.info("CHMOD %s %s", entry.dest, entry.mode)

    def include_manifest_path(self, path):
        with open(path, 'r') as fh:
            self.include_manifest(fh)

    def include_manifest(self, manifest_fh):
        manifest_entries = manifest.read_entries_from(manifest_fh)

        for entry in manifest_entries:
            # Swap out the source with the actual "runfile" location if we're
            # called as a part of the build rather than "bazel run"
            if not CALLED_FROM_BAZEL_RUN and entry.src is not None:
                entry.src = os.path.join(RUNFILE_PREFIX, entry.src)
            # Prepend the destdir path to all installation paths, if one is
            # specified.
            if self.destdir is not None:
                entry.dest = os.path.join(self.destdir, entry.dest)
            self.entries.append(entry)

    def do_the_thing(self):
        for entry in self.entries:
            if entry.type == manifest.ENTRY_IS_FILE:
                self._install_file(entry)
            elif entry.type == manifest.ENTRY_IS_LINK:
                self._install_symlink(entry)
            elif entry.type == manifest.ENTRY_IS_DIR:
                self._install_directory(entry)
            elif entry.type == manifest.ENTRY_IS_TREE:
                self._install_treeartifact(entry)
            else:
                raise ValueError("Unrecognized entry type '{}'".format(entry.type))


def main(args):
    parser = argparse.ArgumentParser(
        prog="bazel run -- {TARGET_LABEL}",
        description='Installer for bazel target {TARGET_LABEL}',
        fromfile_prefix_chars='@',
    )
    parser.add_argument('-v', '--verbose', action='count', default=0,
                        help="Be verbose.  Specify multiple times to increase verbosity further")
    parser.add_argument('-q', '--quiet', action='store_true', default=False,
                        help="Be silent, except for errors")
    # TODO(nacl): consider supporting DESTDIR=/whatever syntax, like "make
    # install".
    #
    # TODO(nacl): consider removing absolute path restriction, perhaps using
    # BUILD_WORKING_DIRECTORY.
    parser.add_argument('--destdir', action='store', default=os.getenv("DESTDIR"),
                        help="Installation root directory (defaults to DESTDIR "
                             "environment variable).  Must be an absolute path.")

    args = parser.parse_args()

    loudness = args.verbose - args.quiet

    if args.quiet:
        logging.getLogger().setLevel(logging.ERROR)
    elif loudness == 0:
        logging.getLogger().setLevel(logging.WARNING)
    elif loudness == 1:
        logging.getLogger().setLevel(logging.INFO)
    else:  # loudness >= 2:
        logging.getLogger().setLevel(logging.DEBUG)

    installer = NativeInstaller(destdir=args.destdir)

    if not CALLED_FROM_BAZEL_RUN and RUNFILE_PREFIX is None:
        logging.critical("RUNFILES_DIR must be set in your environment when this is run as a bazel build tool.")
        logging.critical("This is most likely an issue on Windows.  See https://github.com/bazelbuild/rules_pkg/issues/387.")
        return 1

    for f in ["{MANIFEST_INCLUSION}"]:
        if CALLED_FROM_BAZEL_RUN:
            installer.include_manifest_path(f)
        else:
            installer.include_manifest_path(os.path.join(RUNFILE_PREFIX, f))

    installer.do_the_thing()


if __name__ == "__main__":
    sys.exit(main(sys.argv))

# uutils coreutils is installed beside the bootstrap's GNU coreutils, not on
# top of it: apt, dpkg and Sileo depend on the GNU one being in usr/bin.
#
# This only exports where the utilities are. Opt in per shell with
#
#     export PATH="$UUTILS_BIN:$PATH"
#
# or leave PATH alone and reach them through the multi-call binary:
#
#     coreutils ls -l
UUTILS_BIN="@PREFIX@/@UTILS_DIR@"
export UUTILS_BIN

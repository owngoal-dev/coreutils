# Installed as <prefix>/etc/profile.d/coreutils.sh, the same path and the same
# content the GNU coreutils package used, so replacing it does not change what a
# login shell does. uutils' ls accepts -F, -b, --color and -T, and its dircolors
# emits the same LS_COLORS assignment.
alias ls="ls -Fb --color=auto -T 0"
eval "$(dircolors -b)"
export CLICOLOR=

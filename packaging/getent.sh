#!/bin/sh
#
# A stand-in for getent.
#
# getent is not a coreutils program upstream -- Procursus builds it into its GNU
# coreutils package, and uutils has no equivalent -- so replacing that package
# would otherwise take it off the system. zsh, bash, fish and ex-vi all look it
# up for user and host completion, so answer the databases they ask for. This is
# a subset, not a reimplementation: passwd, group, hosts, ahosts, services,
# protocols and networks, with no key meaning "dump the database", which is what
# those callers use.
#
# Everything here is shell built-ins and redirection. awk and grep are separate
# packages that a bootstrap need not have, and this has to keep working on a
# system whose coreutils just got swapped underneath it. Hosts go through
# dscacheutil when it is present, because Darwin resolves names through
# directory services rather than /etc/hosts alone.

found=0
missing=2
unknown_database=1

database=$1
[ $# -gt 0 ] && shift

is_number() {
    case $1 in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
    esac
}

# Dump every non-comment, non-blank line of a colon-separated database.
dump_colon_file() {
    [ -r "$1" ] || return "$missing"
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
        '#'* | '') continue ;;
        esac
        printf '%s\n' "$line"
    done <"$1"
    return "$found"
}

# Print the lines of a colon-separated database whose name (field 1) or id
# (field 3) equals the key. Numeric keys look at the id, everything else the
# name, which is how getent treats passwd and group.
lookup_colon_file() {
    file=$1
    key=$2
    [ -r "$file" ] || return "$missing"
    status=$missing
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
        '#'* | '') continue ;;
        esac
        name=${line%%:*}
        rest=${line#*:*:}
        id=${rest%%:*}
        if is_number "$key"; then
            [ "$id" = "$key" ] || continue
        else
            [ "$name" = "$key" ] || continue
        fi
        printf '%s\n' "$line"
        status=$found
    done <"$file"
    return "$status"
}

# Pull the addresses out of dscacheutil's key: value output.
#
# This lives in a function rather than inline in the command substitution that
# calls it because bash 3.2 -- which is /bin/sh and /bin/bash on macOS, and so
# the parser the CI runner checks this with -- mis-parses a `case` inside
# `$(...)`: it reads a pattern's closing paren as the end of the substitution.
dscacheutil_addresses() {
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
        ipv4_address:* | ipv6_address:*) printf '%s\n' "${line#*: }" ;;
        esac
    done
}

# Print the /etc/hosts line that lists the key as one of its names.
lookup_hosts_file() {
    key=$1
    [ -r /etc/hosts ] || return "$missing"
    status=$missing
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
        '#'* | '') continue ;;
        esac
        set -- $line
        address=$1
        shift
        for name in "$@"; do
            if [ "$name" = "$key" ]; then
                printf '%s\t%s\n' "$address" "$key"
                status=$found
                break
            fi
        done
    done </etc/hosts
    return "$status"
}

# Print the whitespace-separated database line whose first field, or whose
# port/protocol field, matches the key.
lookup_service_file() {
    file=$1
    key=$2
    [ -r "$file" ] || return "$missing"
    status=$missing
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
        '#'* | '') continue ;;
        esac
        set -- $line
        if [ "$1" = "$key" ] || [ "${2%%/*}" = "$key" ]; then
            printf '%s\n' "$line"
            status=$found
            return "$status"
        fi
    done <"$file"
    return "$status"
}

case $database in
passwd | group)
    file=/etc/$database
    [ $# -gt 0 ] || { dump_colon_file "$file"; exit $?; }
    status=$missing
    for key in "$@"; do
        lookup_colon_file "$file" "$key" && status=$found
    done
    exit "$status"
    ;;
hosts | ahosts | ahostsv4 | ahostsv6)
    if [ $# -eq 0 ]; then
        [ -r /etc/hosts ] || exit "$missing"
        while IFS= read -r line || [ -n "$line" ]; do
            case $line in
            '#'* | '') continue ;;
            esac
            printf '%s\n' "$line"
        done </etc/hosts
        exit "$found"
    fi
    status=$missing
    for key in "$@"; do
        resolved=""
        if command -v dscacheutil >/dev/null 2>&1; then
            resolved=$(dscacheutil -q host -a name "$key" 2>/dev/null | dscacheutil_addresses)
        fi
        if [ -n "$resolved" ]; then
            for address in $resolved; do
                printf '%s\t%s\n' "$address" "$key"
            done
            status=$found
            continue
        fi
        lookup_hosts_file "$key" && status=$found
    done
    exit "$status"
    ;;
services | protocols | networks)
    file=/etc/$database
    [ $# -gt 0 ] || { dump_colon_file "$file"; exit $?; }
    status=$missing
    for key in "$@"; do
        lookup_service_file "$file" "$key" && status=$found
    done
    exit "$status"
    ;;
--help | -h)
    echo "usage: getent database [key ...]"
    echo "databases: passwd group hosts ahosts services protocols networks"
    echo "this is the stand-in shipped by @PACKAGE_ID@, not GNU getent"
    exit "$found"
    ;;
'')
    echo "usage: getent database [key ...]" >&2
    exit "$unknown_database"
    ;;
*)
    echo "getent: unsupported database '$database'" >&2
    echo "getent: this is the stand-in from @PACKAGE_ID@, not GNU getent" >&2
    exit "$unknown_database"
    ;;
esac

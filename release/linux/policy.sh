#!/bin/sh
# Installed root-owned public policy; never load keys, cookies or caller configuration.
frameshift_refuse() {
  printf '%s\n' 'frameshift: installed service policy or directory custody unavailable' >&2
  exit 69
}
frameshift_id() {
  case "$1" in ''|0*|*[!0-9]*) frameshift_refuse ;; esac
  [ "${#1}" -le 10 ] && [ "$1" -le 4294967294 ] || frameshift_refuse
}
frameshift_policy() {
  fs_uid=$(id -u frameshift) || frameshift_refuse
  fs_gid=$(id -g frameshift) || frameshift_refuse
  fs_control=$(getent group frameshift-control | cut -d: -f3)
  fs_observer=$(getent group frameshift-observer | cut -d: -f3)
  for fs_id in "$fs_uid" "$fs_gid" "$fs_control" "$fs_observer"; do frameshift_id "$fs_id"; done
  [ "$fs_control" != "$fs_observer" ] && [ "$fs_gid" != "$fs_control" ] &&
    [ "$fs_gid" != "$fs_observer" ] || frameshift_refuse
  fs_groups=" $(id -G frameshift) "
  case "$fs_groups" in *" $fs_control "*) ;; *) frameshift_refuse ;; esac
  case "$fs_groups" in *" $fs_observer "*) ;; *) frameshift_refuse ;; esac
}

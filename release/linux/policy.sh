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
frameshift_ids() {
  fs_uid=$(id -u frameshift) || frameshift_refuse
  fs_gid=$(id -g frameshift) || frameshift_refuse
  fs_control=$(getent group frameshift-control | cut -d: -f3)
  fs_observer=$(getent group frameshift-observer | cut -d: -f3)
  for fs_id in "$fs_uid" "$fs_gid" "$fs_control" "$fs_observer"; do frameshift_id "$fs_id"; done
  [ "$fs_control" != "$fs_observer" ] && [ "$fs_gid" != "$fs_control" ] &&
    [ "$fs_gid" != "$fs_observer" ] || frameshift_refuse
}
frameshift_policy() {
  frameshift_ids
  fs_groups=" $(id -G frameshift) "
  case "$fs_groups" in *" $fs_control "*) ;; *) frameshift_refuse ;; esac
  case "$fs_groups" in *" $fs_observer "*) ;; *) frameshift_refuse ;; esac
}
frameshift_data_custody() {
  [ ! -L /var/lib/frameshift ] && [ -d /var/lib/frameshift ] &&
    [ "$(stat -c '%u:%g:%a' /var/lib/frameshift)" = "$fs_uid:$fs_gid:700" ] || frameshift_refuse
}
frameshift_working_directory() {
  if [ -r . ] && [ -x . ] && pwd -P >/dev/null 2>&1; then return; fi
  # Never reinterpret a relative file argument after moving away from its caller.
  for fs_path do case "$fs_path" in /*) ;; *) frameshift_refuse ;; esac; done
  cd / || frameshift_refuse
}

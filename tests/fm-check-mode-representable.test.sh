#!/usr/bin/env bash
# Behavior tests for the mode-representable probe (bin/fm-pr-lib.sh) and for the
# custom watcher check authentication that depends on it
# (bin/fm-check-register.sh, bin/fm-check-lib.sh).
#
# Some filesystems cannot represent Unix modes: a 9p/DrvFs Windows mount under
# WSL reports every file as 777 and accepts chmod silently without changing
# anything. An exact-mode assertion there can never pass, so a home on such a
# mount could neither register a watcher check nor verify one it had registered.
#
# CI has no such mount, so the mode-blind case is reproduced with a PATH shim
# that exhibits exactly the two properties observed on the real thing: `chmod`
# succeeds and changes nothing, and `stat -c %a` always answers 777. Every other
# stat field, and every other tool, stays real. That shim's verdicts were
# cross-checked against a real 9p mount, where registering and verifying behave
# as they do here.
#
# The security control these tests must hold is the hash binding, not the mode
# bits: a check script whose bytes changed has to be refused even where the mode
# assertion is skipped.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REGISTER="$ROOT/bin/fm-check-register.sh"
TMP_ROOT=$(fm_test_tmproot fm-check-mode-representable)
REAL_STAT=$(command -v stat)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

write_check() {
  local home=$1 id=$2
  cat > "$home/state/$id.check.sh" <<'SH'
#!/usr/bin/env bash
printf 'custom-ready\n'
SH
  chmod 0700 "$home/state/$id.check.sh"
}

# A PATH shim reproducing a filesystem that cannot represent modes: chmod is
# accepted and ignored, and the mode read back is always 777.
mode_blind_bin() {
  local home=$1 fakebin
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/chmod" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/stat" <<SH
#!/usr/bin/env bash
if [ "\${1-}" = -c ] && [ "\${2-}" = %a ]; then
  shift 2
  for _f in "\$@"; do
    [ -e "\$_f" ] || exit 1
    printf '777\n'
  done
  exit 0
fi
exec "$REAL_STAT" "\$@"
SH
  chmod +x "$fakebin/chmod" "$fakebin/stat"
  printf '%s\n' "$fakebin"
}

# A PATH shim where chmod itself fails, so the probe cannot conclude anything.
chmod_broken_bin() {
  local home=$1 fakebin
  fakebin="$home/brokenbin"
  mkdir -p "$fakebin"
  cat > "$fakebin/chmod" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/chmod"
  printf '%s\n' "$fakebin"
}

# run_lib <path-prefix-or-empty> <function> [args...] - call a library function
# with bin/fm-pr-lib.sh and bin/fm-check-lib.sh sourced, optionally under a
# PATH shim. Exit status is the function's own.
run_lib() {
  local prefix=$1 run_path
  shift
  run_path=$PATH
  [ -z "$prefix" ] || run_path="$prefix:$PATH"
  PATH="$run_path" bash -c '
    set -u
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-check-lib.sh"
    shift
    "$@"
  ' _ "$ROOT" "$@"
}

assert_no_probe_left() {
  local dir=$1 msg=$2 leaked
  leaked=$(find "$dir" -maxdepth 1 -name '.fm-mode-probe.*' 2>/dev/null)
  [ -z "$leaked" ] || fail "$msg (left behind: $leaked)"
}

# The POSIX-filesystem half of every test below is only meaningful if the
# fixture root really does represent modes. Say so loudly rather than passing
# vacuously on an exotic TMPDIR.
assert_fixture_filesystem_represents_modes() {
  local probe
  probe=$(mktemp "$TMP_ROOT/.fixture-mode-check.XXXXXX") || fail "cannot write to the fixture root"
  chmod 0700 "$probe" || fail "cannot chmod inside the fixture root"
  if [ "$(stat -c %a "$probe" 2>/dev/null || stat -f %Lp "$probe")" != 700 ]; then
    rm -f -- "$probe"
    fail "TMPDIR cannot represent file modes; set TMPDIR to a POSIX filesystem to run this suite"
  fi
  rm -f -- "$probe"
}

test_probe_answers_per_filesystem_and_leaves_nothing_behind() {
  local home fakebin status
  home=$(make_home probe)

  status=0
  run_lib '' fm_pr_mode_representable "$home/state" 700 || status=$?
  expect_code 0 "$status" "probe on a POSIX filesystem for mode 700"
  status=0
  run_lib '' fm_pr_mode_representable "$home/state" 600 || status=$?
  expect_code 0 "$status" "probe on a POSIX filesystem for mode 600"
  assert_no_probe_left "$home/state" "POSIX probe left its temp file behind"

  fakebin=$(mode_blind_bin "$home")
  status=0
  run_lib "$fakebin" fm_pr_mode_representable "$home/state" 700 || status=$?
  expect_code 1 "$status" "probe where modes are ignored, for mode 700"
  status=0
  run_lib "$fakebin" fm_pr_mode_representable "$home/state" 600 || status=$?
  expect_code 1 "$status" "probe where modes are ignored, for mode 600"
  assert_no_probe_left "$home/state" "mode-blind probe left its temp file behind"

  pass "the probe reports mode support per filesystem and cleans up after itself"
}

test_probe_enforces_when_it_cannot_conclude() {
  local home brokenbin status
  home=$(make_home inconclusive)

  status=0
  run_lib '' fm_pr_mode_representable "$home/state/missing-dir" 700 || status=$?
  expect_code 0 "$status" "probe that cannot create its temp file must keep enforcement on"

  brokenbin=$(chmod_broken_bin "$home")
  status=0
  run_lib "$brokenbin" fm_pr_mode_representable "$home/state" 700 || status=$?
  expect_code 0 "$status" "probe whose chmod fails must keep enforcement on"
  assert_no_probe_left "$home/state" "inconclusive probe left its temp file behind"

  pass "an inconclusive probe keeps the strict mode assertion rather than dropping it"
}

test_registration_and_verification_work_where_modes_are_ignored() {
  local home fakebin out err status
  home=$(make_home mode-blind)
  out="$home/out.txt"
  err="$home/err.txt"
  write_check "$home" blind-check
  fakebin=$(mode_blind_bin "$home")

  status=0
  PATH="$fakebin:$PATH" FM_HOME="$home" "$REGISTER" blind-check >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "register where modes are ignored"
  assert_contains "$(cat "$out")" "registered: state/blind-check.check.sh" \
    "register produced no confirmation where modes are ignored"
  assert_present "$home/state/blind-check.check-trust" "register wrote no trust binding"

  status=0
  run_lib "$fakebin" fm_custom_check_registered "$home/state" blind-check || status=$?
  expect_code 0 "$status" "verify a registered check where modes are ignored"
  status=0
  run_lib "$fakebin" fm_custom_check_snapshot_prepare "$home/state" blind-check || status=$?
  expect_code 0 "$status" "snapshot a registered check where modes are ignored"
  assert_no_probe_left "$home/state" "registration left a probe temp file behind"

  pass "a home on a filesystem that ignores modes can register and verify a check"
}

test_tampered_check_is_still_rejected_where_modes_are_ignored() {
  local home fakebin status
  home=$(make_home tamper)
  write_check "$home" tampered
  fakebin=$(mode_blind_bin "$home")
  PATH="$fakebin:$PATH" FM_HOME="$home" "$REGISTER" tampered >/dev/null 2>&1 \
    || fail "could not register the fixture check"

  status=0
  run_lib "$fakebin" fm_custom_check_registered "$home/state" tampered || status=$?
  expect_code 0 "$status" "the untampered check must verify first"

  # One character: the check now reports something the supervisor would act on.
  printf '#!/usr/bin/env bash\nprintf "custom-reads\\n"\n' > "$home/state/tampered.check.sh"

  status=0
  run_lib "$fakebin" fm_custom_check_registered "$home/state" tampered || status=$?
  expect_code 1 "$status" "a tampered check must be refused even where modes are ignored"
  status=0
  run_lib "$fakebin" fm_custom_check_snapshot_prepare "$home/state" tampered || status=$?
  expect_code 1 "$status" "a tampered check must not reach the snapshot the watcher executes"

  # And the trust file itself cannot be swapped for one naming the new bytes
  # unless the operator re-registers deliberately.
  printf 'fm-custom-check-v1\n%s\n' "$(printf '0%.0s' $(seq 1 64))" \
    > "$home/state/tampered.check-trust"
  status=0
  run_lib "$fakebin" fm_custom_check_registered "$home/state" tampered || status=$?
  expect_code 1 "$status" "a trust binding naming other bytes must be refused"

  pass "the hash binding still refuses tampered bytes where the mode assertion is skipped"
}

test_unregistered_check_is_still_refused_where_modes_are_ignored() {
  local home fakebin status
  home=$(make_home unregistered)
  write_check "$home" intruder
  fakebin=$(mode_blind_bin "$home")

  # Never registered: the mode assertion being skipped must not stand in for
  # the trust binding, or a planted check would reach the watcher's executor.
  status=0
  run_lib "$fakebin" fm_custom_check_snapshot_prepare "$home/state" intruder || status=$?
  expect_code 1 "$status" "an unregistered check must be refused where modes are ignored"

  # A trust binding is not enough either; it has to name these bytes.
  printf 'fm-custom-check-v1\n%s\n' "$(printf 'a%.0s' $(seq 1 64))" \
    > "$home/state/intruder.check-trust"
  status=0
  run_lib "$fakebin" fm_custom_check_snapshot_prepare "$home/state" intruder || status=$?
  expect_code 1 "$status" "a trust binding for other bytes must be refused where modes are ignored"

  pass "a check without a matching trust binding is refused where modes are ignored"
}

test_wrong_mode_is_still_rejected_on_a_posix_filesystem() {
  local home out err status
  home=$(make_home posix)
  out="$home/out.txt"
  err="$home/err.txt"
  write_check "$home" posix-check
  FM_HOME="$home" "$REGISTER" posix-check >"$out" 2>"$err" \
    || fail "could not register a 0700 check on a POSIX filesystem"
  status=0
  run_lib '' fm_custom_check_registered "$home/state" posix-check || status=$?
  expect_code 0 "$status" "a 0700 check must verify on a POSIX filesystem"

  # Widen the mode without touching a byte: the hash still matches, so only the
  # mode assertion can catch this, and on a POSIX filesystem it must.
  chmod 0777 "$home/state/posix-check.check.sh"
  status=0
  run_lib '' fm_custom_check_registered "$home/state" posix-check || status=$?
  expect_code 1 "$status" "a world-writable check must stay refused on a POSIX filesystem"
  status=0
  run_lib '' fm_custom_check_snapshot_prepare "$home/state" posix-check || status=$?
  expect_code 1 "$status" "a world-writable check must not reach the executed snapshot"

  rm -f "$home/state/posix-check.check-trust"
  status=0
  FM_HOME="$home" "$REGISTER" posix-check >"$out" 2>"$err" || status=$?
  expect_code 1 "$status" "register must refuse a world-writable check on a POSIX filesystem"
  assert_contains "$(cat "$err")" "custom check is unavailable" \
    "wrong-mode refusal used the wrong stderr"
  assert_absent "$home/state/posix-check.check-trust" \
    "a refused registration still wrote a trust binding"

  chmod 0700 "$home/state/posix-check.check.sh"
  status=0
  FM_HOME="$home" "$REGISTER" posix-check >"$out" 2>"$err" || status=$?
  expect_code 0 "$status" "register must accept the check again once its mode is restored"

  # The trust file's own 0600 assertion is enforced here too.
  chmod 0644 "$home/state/posix-check.check-trust"
  status=0
  run_lib '' fm_custom_check_registered "$home/state" posix-check || status=$?
  expect_code 1 "$status" "a readable trust binding must stay refused on a POSIX filesystem"

  assert_no_probe_left "$home/state" "POSIX rejections left a probe temp file behind"

  pass "mode enforcement on a POSIX filesystem is unchanged"
}

assert_fixture_filesystem_represents_modes
test_probe_answers_per_filesystem_and_leaves_nothing_behind
test_probe_enforces_when_it_cannot_conclude
test_registration_and_verification_work_where_modes_are_ignored
test_tampered_check_is_still_rejected_where_modes_are_ignored
test_unregistered_check_is_still_refused_where_modes_are_ignored
test_wrong_mode_is_still_rejected_on_a_posix_filesystem

#!/bin/sh
# Integration tests for timeout. POSIX sh.
# Usage: sh test.sh [path-to-timeout-binary]

set -Cue

g_timeout="${1:-./timeout}"
g_pass=0
g_fail=0
g_tmp=$(mktemp -d)

fn_ontrap() {
	rm -rf "$g_tmp"
}
trap fn_ontrap EXIT INT TERM

fn_ok() {
	g_pass=$((g_pass + 1))
	printf '  ok   %s\n' "$1"
}

fn_fail() {
	g_fail=$((g_fail + 1))
	printf '  FAIL %s\n' "$1"
}

# fn_assert_exit <desc> <expected> <actual>
fn_assert_exit() {
	if test "$2" = "$3"; then
		fn_ok "$1 (exit=$3)"
	else
		fn_fail "$1 (expected $2, got $3)"
	fi
}

# fn_assert_file_contains <desc> <file> <pattern>
fn_assert_file_contains() {
	if grep -q "$3" "$2" 2> /dev/null; then
		fn_ok "$1"
	else
		fn_fail "$1 (missing '$3' in $2)"
	fi
}

# fn_trap_script
# Writes a helper script that logs received signals to a file (passed as $1 at runtime).
fn_trap_script() {
	cat >| "$g_tmp/trap.sh" << 'TRAP'
trap 'echo "INT" >> "$1"; exit 0' INT
trap 'echo "TERM" >> "$1"; exit 0' TERM
trap 'echo "HUP" >> "$1"' HUP
sleep 60 &
wait $!
TRAP
	chmod +x "$g_tmp/trap.sh"
}

# fn_ignore_term_script
# Writes a helper that ignores TERM.
fn_ignore_term_script() {
	cat >| "$g_tmp/ignore_term.sh" << 'IGNORE'
trap '' TERM
sleep 60 &
wait $!
IGNORE
	chmod +x "$g_tmp/ignore_term.sh"
}

# fn_child_script
# Writes a helper that spawns a child, traps TERM, and kills the child.
fn_child_script() {
	cat >| "$g_tmp/child.sh" << 'CHILD'
sh -c 'sleep 60' &
b_child=$!
trap 'echo "parent-TERM" >> "$1"; kill "$b_child" 2>/dev/null; exit 0' TERM
sleep 60 &
wait $!
CHILD
	chmod +x "$g_tmp/child.sh"
}

echo "== exit codes =="

b_rc=0
"$g_timeout" 10 sh -c 'exit 0' || b_rc=$?
fn_assert_exit "no timeout, exit 0" 0 "$b_rc"

b_rc=0
"$g_timeout" 10 sh -c 'exit 42' || b_rc=$?
fn_assert_exit "no timeout, exit 42" 42 "$b_rc"

b_rc=0
"$g_timeout" 1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "timeout → 124" 124 "$b_rc"

b_rc=0
"$g_timeout" 1 nonexistent-cmd-xyz 2> /dev/null || b_rc=$?
fn_assert_exit "not found → 127" 127 "$b_rc"

echo "== -p preserve status =="

b_rc=0
"$g_timeout" -p 10 sh -c 'exit 7' || b_rc=$?
fn_assert_exit "-p, no timeout, exit 7" 7 "$b_rc"

b_rc=0
"$g_timeout" -p 1 sleep 10 2> /dev/null || b_rc=$?
if test "$b_rc" = "143" || test "$b_rc" = "124"; then
	fn_ok "-p with timeout (exit=$b_rc)"
else
	fn_fail "-p with timeout (expected 143 or 124, got $b_rc)"
fi

echo "== -s custom signal =="

b_siglog="$g_tmp/sig.log"
: >| "$b_siglog"
fn_trap_script "$b_siglog"

b_rc=0
"$g_timeout" -s INT 2 sh "$g_tmp/trap.sh" "$b_siglog" || b_rc=$?
fn_assert_exit "-s INT → 124" 124 "$b_rc"
fn_assert_file_contains "INT was delivered" "$b_siglog" "INT"

b_siglog="$g_tmp/sig_hup.log"
: >| "$b_siglog"
b_rc=0
"$g_timeout" -s HUP 2 sh "$g_tmp/trap.sh" "$b_siglog" || b_rc=$?
fn_assert_file_contains "HUP was delivered" "$b_siglog" "HUP"

echo "== -k kill-after =="

fn_ignore_term_script
b_start=$(date +%s)
b_rc=0
"$g_timeout" -k 1 1 sh "$g_tmp/ignore_term.sh" 2> /dev/null || b_rc=$?
b_end=$(date +%s)
b_dt=$((b_end - b_start))
fn_assert_exit "-k 1, ignore TERM → 137 (SIGKILL)" 137 "$b_rc"
if test "$b_dt" -ge 1 && test "$b_dt" -le 4; then
	fn_ok "-k 1 took ~${b_dt}s (expected ~2s)"
else
	fn_fail "-k 1 took ${b_dt}s (expected ~2s, range 1-4)"
fi

echo "== -f signal child only =="

fn_child_script "$g_tmp/f.log"
b_rc=0
"$g_timeout" -f -s TERM 2 sh "$g_tmp/child.sh" "$g_tmp/f.log" 2> /dev/null || b_rc=$?
fn_assert_file_contains "-f: parent got TERM" "$g_tmp/f.log" "parent-TERM"

echo "== stdin inheritance =="

b_result=$(echo "pipe-test" | "$g_timeout" 5 cat)
if test "$b_result" = "pipe-test"; then
	fn_ok "stdin inherited"
else
	fn_fail "stdin inherited (got '$b_result')"
fi

echo "== 0 duration = no timeout =="

b_rc=0
"$g_timeout" 0 sh -c 'sleep 1; exit 9' || b_rc=$?
fn_assert_exit "0 duration, no timeout, exit 9" 9 "$b_rc"

echo "== duration parsing =="

b_rc=0
"$g_timeout" 0.5d sh -c 'exit 3' || b_rc=$?
fn_assert_exit "0.5d parses, exit 3" 3 "$b_rc"

b_rc=0
"$g_timeout" 1d sh -c 'exit 5' || b_rc=$?
fn_assert_exit "1d parses, exit 5" 5 "$b_rc"

b_rc=0
"$g_timeout" "abc" sh -c 'echo hi' 2> /dev/null || b_rc=$?
fn_assert_exit "invalid duration → 125" 125 "$b_rc"

b_rc=0
"$g_timeout" -k "-2" 1 sh -c 'echo hi' 2> /dev/null || b_rc=$?
fn_assert_exit "invalid kill delay → 125" 125 "$b_rc"

b_rc=0
"$g_timeout" -s "BOGUS" 1 sh -c 'echo hi' 2> /dev/null || b_rc=$?
fn_assert_exit "invalid signal → 125" 125 "$b_rc"

echo "== -s numeric and SIG-prefixed signals =="

b_rc=0
"$g_timeout" -s 15 1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "-s 15 (TERM) → 124" 124 "$b_rc"

b_rc=0
"$g_timeout" -s 9 1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "-s 9 (KILL) → 137 (SIGKILL status)" 137 "$b_rc"

b_rc=0
"$g_timeout" -s SIGTERM 1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "-s SIGTERM → 124" 124 "$b_rc"

b_rc=0
"$g_timeout" -s sigint 1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "-s sigint → 124" 124 "$b_rc"

b_rc=0
"$g_timeout" -s 0 1 sh -c 'echo hi' 2> /dev/null || b_rc=$?
fn_assert_exit "-s 0 → 125" 125 "$b_rc"

b_rc=0
"$g_timeout" -s 200 1 sh -c 'echo hi' 2> /dev/null || b_rc=$?
fn_assert_exit "-s 200 → 125" 125 "$b_rc"

echo "== -s and -k equals form =="

b_rc=0
"$g_timeout" -s=TERM 1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "-s=TERM → 124" 124 "$b_rc"

b_rc=0
"$g_timeout" -s=KILL 1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "-s=KILL → 137" 137 "$b_rc"

b_rc=0
"$g_timeout" -k=1 1 sh "$g_tmp/ignore_term.sh" 2> /dev/null || b_rc=$?
fn_assert_exit "-k=1, ignore TERM → 137" 137 "$b_rc"

b_rc=0
"$g_timeout" -s=15 1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "-s=15 → 124" 124 "$b_rc"

echo "== negative duration =="

b_rc=0
"$g_timeout" -1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "-1 duration → 125" 125 "$b_rc"

b_rc=0
"$g_timeout" -- -1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "-- -1 duration → 125" 125 "$b_rc"

b_rc=0
"$g_timeout" -1.5d sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "-1.5d duration → 125" 125 "$b_rc"

b_rc=0
"$g_timeout" -2s sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "-2s duration → 125" 125 "$b_rc"

echo "== signal forwarding =="

# child signals itself → timeout forwards the signal
b_rc=0
"$g_timeout" 10 sh -c 'kill -INT $$' 2> /dev/null || b_rc=$?
fn_assert_exit "self INT → 130" 130 "$b_rc"

b_rc=0
"$g_timeout" -p 10 sh -c 'kill -INT $$' 2> /dev/null || b_rc=$?
fn_assert_exit "-p self INT → 130" 130 "$b_rc"

b_rc=0
"$g_timeout" 10 sh -c 'kill -TERM $$' 2> /dev/null || b_rc=$?
fn_assert_exit "self TERM → 143" 143 "$b_rc"

echo "== not executable =="

b_noexec="$g_tmp/noexec"
printf '#!/bin/sh\n' >| "$b_noexec"
chmod 644 "$b_noexec"
b_rc=0
"$g_timeout" 10 "$b_noexec" 2> /dev/null || b_rc=$?
fn_assert_exit "not executable → 126" 126 "$b_rc"

echo "== -k 0 immediate kill =="

fn_ignore_term_script
b_start=$(date +%s)
b_rc=0
"$g_timeout" -k 0 1 sh "$g_tmp/ignore_term.sh" 2> /dev/null || b_rc=$?
b_end=$(date +%s)
b_dt=$((b_end - b_start))
fn_assert_exit "-k 0, ignore TERM → 137 (SIGKILL)" 137 "$b_rc"
if test "$b_dt" -le 3; then
	fn_ok "-k 0 took ~${b_dt}s (expected ~1s)"
else
	fn_fail "-k 0 took ${b_dt}s (expected ~1s)"
fi

echo "== -p -k preserve status with kill-after =="

b_rc=0
"$g_timeout" -p -k 1 1 sh "$g_tmp/ignore_term.sh" 2> /dev/null || b_rc=$?
fn_assert_exit "-p -k 1 → 137 (SIGKILL forwarded)" 137 "$b_rc"

echo "== -s KILL as timeout signal =="

b_rc=0
"$g_timeout" -s KILL 1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "-s KILL → 137 (SIGKILL status)" 137 "$b_rc"

echo "== sub-second duration =="

b_rc=0
"$g_timeout" 0.1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "0.1s → 124" 124 "$b_rc"

echo "== process group signaling =="

# Portable PGID lookup: uses procfs on Linux, ps on macOS/BSD
fn_get_pgid() {
	if test -r "/proc/$1/stat"; then
		awk '{print $5}' "/proc/$1/stat" | tr -d ' '
	else
		ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '
	fi
}

b_pgfile="$g_tmp/pgid.txt"
cat >| "$g_tmp/pgid_test.sh" << 'PG'
if test -r "/proc/$$/stat"; then
	awk '{print $5}' "/proc/$$/stat"
else
	ps -o pgid= -p $$ 2>/dev/null
fi | tr -d ' ' > "$1"
sleep 5
PG

# without -f: child gets its own process group (Setpgid)
"$g_timeout" 5 sh "$g_tmp/pgid_test.sh" "$b_pgfile" 2> /dev/null || true
b_my_pgid=$(fn_get_pgid $$)
b_child_pgid=$(cat "$b_pgfile" 2> /dev/null)
if test -n "$b_child_pgid" && test "$b_child_pgid" != "$b_my_pgid"; then
	fn_ok "no -f: child pgid=$b_child_pgid != my pgid=$b_my_pgid (new group)"
else
	fn_fail "no -f: child pgid=$b_child_pgid should differ from my pgid=$b_my_pgid"
fi

# with -f: child stays in the same process group
"$g_timeout" -f 5 sh "$g_tmp/pgid_test.sh" "$b_pgfile" 2> /dev/null || true
b_child_pgid=$(cat "$b_pgfile" 2> /dev/null)
if test -n "$b_child_pgid" && test "$b_child_pgid" = "$b_my_pgid"; then
	fn_ok "-f: child pgid=$b_child_pgid == my pgid=$b_my_pgid (same group)"
else
	fn_fail "-f: child pgid=$b_child_pgid should match my pgid=$b_my_pgid"
fi

echo "== usage / arg validation =="

b_rc=0
"$g_timeout" 2> /dev/null || b_rc=$?
fn_assert_exit "no args → 125" 125 "$b_rc"

b_rc=0
"$g_timeout" 10 2> /dev/null || b_rc=$?
fn_assert_exit "missing command → 125" 125 "$b_rc"

b_rc=0
"$g_timeout" -- 10 sh -c 'exit 3' || b_rc=$?
fn_assert_exit "-- end of options" 3 "$b_rc"

b_rc=0
"$g_timeout" --help > /dev/null 2>&1 || b_rc=$?
fn_assert_exit "--help → 0" 0 "$b_rc"

b_rc=0
"$g_timeout" -h > /dev/null 2>&1 || b_rc=$?
fn_assert_exit "-h → 0" 0 "$b_rc"

echo "== long options =="

b_rc=0
"$g_timeout" --foreground 1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "--foreground → 124" 124 "$b_rc"

b_rc=0
"$g_timeout" --preserve-status 10 sh -c 'exit 7' 2> /dev/null || b_rc=$?
fn_assert_exit "--preserve-status, no timeout → 7" 7 "$b_rc"

b_rc=0
"$g_timeout" --signal=TERM 1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "--signal=TERM → 124" 124 "$b_rc"

b_rc=0
"$g_timeout" --signal KILL 1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "--signal KILL → 137" 137 "$b_rc"

b_rc=0
"$g_timeout" --kill-after=1 1 sh "$g_tmp/ignore_term.sh" 2> /dev/null || b_rc=$?
fn_assert_exit "--kill-after=1, ignore TERM → 137" 137 "$b_rc"

b_rc=0
"$g_timeout" --signal INT 2 sh "$g_tmp/trap.sh" "$b_siglog" 2> /dev/null || b_rc=$?
fn_assert_exit "--signal INT → 124" 124 "$b_rc"

b_rc=0
"$g_timeout" --kill-after 1 1 sh "$g_tmp/ignore_term.sh" 2> /dev/null || b_rc=$?
fn_assert_exit "--kill-after 1 (space form) → 137" 137 "$b_rc"

echo "== combined short flags =="

b_rc=0
"$g_timeout" -fp 10 sh -c 'exit 3' 2> /dev/null || b_rc=$?
fn_assert_exit "-fp (foreground+preserve) → 3" 3 "$b_rc"

b_rc=0
"$g_timeout" -fsKILL 1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "-fsKILL (foreground+signal=KILL) → 137" 137 "$b_rc"

b_rc=0
"$g_timeout" -pf 1 sleep 10 2> /dev/null || b_rc=$?
fn_assert_exit "-pf (preserve+foreground) → 143" 143 "$b_rc"

echo "== verbose =="

b_vout=$("$g_timeout" --verbose 1 sleep 10 2>&1 1>/dev/null || true)
if echo "$b_vout" | grep -q 'sending signal TERM'; then
	fn_ok "--verbose prints signal sent"
else
	fn_fail "--verbose should print signal sent (got: $b_vout)"
fi

b_vout=$("$g_timeout" -v -k 1 1 sh "$g_tmp/ignore_term.sh" 2>&1 1>/dev/null || true)
if echo "$b_vout" | grep -q 'sending signal TERM' && echo "$b_vout" | grep -q 'sending signal KILL'; then
	fn_ok "-v -k prints both TERM and KILL"
else
	fn_fail "-v -k should print both TERM and KILL (got: $b_vout)"
fi

echo "== version =="

b_rc=0
"$g_timeout" --version > /dev/null 2>&1 || b_rc=$?
fn_assert_exit "--version → 0" 0 "$b_rc"

b_vout=$("$g_timeout" --version 2>&1)
if echo "$b_vout" | grep -q 'timeout'; then
	fn_ok "--version output contains 'timeout'"
else
	fn_fail "--version output should contain 'timeout' (got: $b_vout)"
fi

b_rc=0
"$g_timeout" -V > /dev/null 2>&1 || b_rc=$?
fn_assert_exit "-V → 0" 0 "$b_rc"

# --- summary ---

echo ""
echo "=============================="
printf '  %d passed, %d failed\n' "$g_pass" "$g_fail"
echo "=============================="

test "$g_fail" -eq 0

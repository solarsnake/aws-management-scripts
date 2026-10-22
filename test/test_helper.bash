# Shared helpers for the bats suites. Puts the stub aws first on PATH.

SCRIPT_DIR="$BATS_TEST_DIRNAME/.."

setup_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/fixtures"
  export AWS_STUB_FIXTURES="$BATS_TEST_TMPDIR/fixtures"
  export AWS_STUB_LOG="$BATS_TEST_TMPDIR/aws.log"
  : > "$AWS_STUB_LOG"
  export PATH="$BATS_TEST_DIRNAME/bin:$PATH"
  fixture sts_get-caller-identity '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/test","UserId":"AIDTEST"}'
  fixture_script configure_get 'echo us-east-1'
}

fixture() { printf '%s\n' "$2" > "$AWS_STUB_FIXTURES/$1.json"; }

fixture_script() { printf '%s\n' "$2" > "$AWS_STUB_FIXTURES/$1.sh"; }

call_count() {
  local n
  n=$(grep -c -- "^$1 $2" "$AWS_STUB_LOG" || true)
  printf '%s\n' "$n"
}

_matching_calls() {
  local service=$1 op=$2 line s ok
  shift 2
  while IFS= read -r line; do
    case "$line" in "$service $op" | "$service $op "*) ;; *) continue ;; esac
    ok=1
    for s in "$@"; do
      case "$line" in *"$s"*) ;; *) ok=0 ;; esac
    done
    if [ "$ok" = 1 ]; then printf '%s\n' "$line"; fi
  done < "$AWS_STUB_LOG"
}

assert_called() {
  local out
  out=$(_matching_calls "$@")
  if [ -z "$out" ]; then
    echo "expected call: $*" >&2
    echo "aws log:" >&2
    cat "$AWS_STUB_LOG" >&2
    return 1
  fi
}

refute_called() {
  local out
  out=$(_matching_calls "$@")
  if [ -n "$out" ]; then
    echo "unexpected call: $*" >&2
    echo "aws log:" >&2
    cat "$AWS_STUB_LOG" >&2
    return 1
  fi
}

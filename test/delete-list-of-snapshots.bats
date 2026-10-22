setup() { load test_helper; setup_stub; }

S="$BATS_TEST_DIRNAME/../ec2/delete-list-of-snapshots.sh"

mkfile() { printf '%b' "$1" > "$BATS_TEST_TMPDIR/ids.txt"; }

@test "deletes each listed snapshot after yes" {
  mkfile 'snap-00000001\nsnap-00000002\n'
  run bash -c "echo y | '$S' --file '$BATS_TEST_TMPDIR/ids.txt'"
  [ "$status" -eq 0 ]
  [ "$(call_count ec2 delete-snapshot)" -eq 2 ]
}

@test "answering no deletes nothing and exits 1" {
  mkfile 'snap-00000001\nsnap-00000002\n'
  run bash -c "echo n | '$S' --file '$BATS_TEST_TMPDIR/ids.txt'"
  [ "$status" -eq 1 ]
  [ "$(call_count ec2 delete-snapshot)" -eq 0 ]
}

@test "--dry-run deletes nothing and exits 0" {
  mkfile 'snap-00000001\nsnap-00000002\n'
  run "$S" --dry-run --file "$BATS_TEST_TMPDIR/ids.txt"
  [ "$status" -eq 0 ]
  [ "$(call_count ec2 delete-snapshot)" -eq 0 ]
}

@test "CRLF, comments and blanks are handled" {
  mkfile '# header\r\nsnap-00000001\r\n\r\n  snap-00000002  \r\n# end\r\n'
  run "$S" --yes --file "$BATS_TEST_TMPDIR/ids.txt"
  [ "$status" -eq 0 ]
  [ "$(call_count ec2 delete-snapshot)" -eq 2 ]
  assert_called ec2 delete-snapshot --snapshot-id\ snap-00000001
  assert_called ec2 delete-snapshot --snapshot-id\ snap-00000002
}

@test "invalid id exits 2 before any aws call" {
  mkfile 'snap-00000001\nnot-an-id\n'
  run "$S" --yes --file "$BATS_TEST_TMPDIR/ids.txt"
  [ "$status" -eq 2 ]
  ! grep -q '^ec2' "$AWS_STUB_LOG"
}

@test "a failed delete continues and exits 1" {
  mkfile 'snap-00000001\nsnap-00000002\nsnap-00000003\n'
  fixture_script ec2_delete-snapshot 'case "$*" in *snap-00000002*) echo "An error occurred (InvalidSnapshot.InUse)" >&2; exit 1 ;; esac'
  run "$S" --yes --file "$BATS_TEST_TMPDIR/ids.txt"
  [ "$status" -eq 1 ]
  [ "$(call_count ec2 delete-snapshot)" -eq 3 ]
  [[ "$output" == *"Done: 2 succeeded, 1 failed"* ]]
  [[ "$output" == *"Failed: snap-00000002"* ]]
}

@test "reads ids from stdin with --file -" {
  run bash -c "printf 'snap-00000001\nsnap-00000002\n' | '$S' --yes --file -"
  [ "$status" -eq 0 ]
  [ "$(call_count ec2 delete-snapshot)" -eq 2 ]
}

@test "missing --file is usage error" {
  run "$S" --yes
  [ "$status" -eq 2 ]
}

@test "nothing to do" {
  mkfile '# only a comment\n\n'
  run "$S" --file "$BATS_TEST_TMPDIR/ids.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nothing to do."* ]]
  [[ "$output" != *"[y/N]"* ]]
  [ "$(call_count ec2 delete-snapshot)" -eq 0 ]
}

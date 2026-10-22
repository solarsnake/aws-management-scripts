setup() { load test_helper; setup_stub; }

S="$BATS_TEST_DIRNAME/../s3/list-encryption-for-s3-buckets.sh"

four_buckets() {
  fixture s3api_list-buckets '{"Buckets":[{"Name":"kms-b"},{"Name":"sse-b"},{"Name":"none-b"},{"Name":"denied-b"}]}'
  fixture_script s3api_get-bucket-encryption 'case "$*" in
  *kms-b*) echo "{\"ServerSideEncryptionConfiguration\":{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"arn:aws:kms:us-east-1:1:key/abc\"},\"BucketKeyEnabled\":true}]}}" ;;
  *sse-b*) echo "{\"ServerSideEncryptionConfiguration\":{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"}}]}}" ;;
  *none-b*) echo "An error occurred (ServerSideEncryptionConfigurationNotFoundError) when calling the GetBucketEncryption operation" >&2; exit 254 ;;
  *) echo "An error occurred (AccessDenied) when calling the GetBucketEncryption operation: Access Denied" >&2; exit 254 ;;
esac'
}

@test "prints table for kms, sse-s3, none and access denied" {
  four_buckets
  run bash -c "'$S' 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" =~ ^BUCKET\ +ALGORITHM\ +KMS\ KEY\ +BUCKET\ KEY\ +ERROR ]]
  [[ "$output" =~ kms-b\ +aws:kms\ +arn:aws:kms:us-east-1:1:key/abc\ +true ]]
  [[ "$output" =~ sse-b\ +AES256\ +-\ +false ]]
  [[ "$output" =~ none-b\ +none ]]
  [[ "$output" =~ denied-b\ +error\ +-\ +-\ +AccessDenied ]]
}

@test "--json output is valid and complete" {
  four_buckets
  run bash -c "'$S' --json 2>/dev/null | jq -e 'length == 4 and (map(select(.bucket==\"denied-b\"))[0].error == \"AccessDenied\") and (map(select(.bucket==\"none-b\"))[0].algorithm == \"none\") and (map(select(.bucket==\"sse-b\"))[0].error == null)'"
  [ "$status" -eq 0 ]
}

@test "no buckets prints header only and exits 0" {
  fixture s3api_list-buckets '{"Buckets":[]}'
  run bash -c "'$S' 2>/dev/null"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == BUCKET* ]]
}

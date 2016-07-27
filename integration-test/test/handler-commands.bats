#!/usr/bin/env bats

load test_helper

setup(){
    build_docker_image
}

teardown(){
    rm -rf "$certs_dir"
}

@test "handler command: install - creates the data dir" {
    run in_container fake-waagent install
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" = *event=installed* ]]

    diff="$(container_diff)"
    echo "$diff"
    [[ "$diff" = *"A /var/lib/azure/custom-script"* ]]
}

@test "handler command: enable - can process empty settings, but fails" {
    mk_container sh -c "fake-waagent install && fake-waagent enable"
    push_settings '' ''

    run start_container
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid configuration: 'commandToExecute' is not specified"* ]]

     # Validate .status file says enable failed
     diff="$(container_diff)"; echo "$diff"
    [[ "$diff" = *"A /var/lib/waagent/Extension/status/0.status"* ]]
    status_file="$(container_read_file /var/lib/waagent/Extension/status/0.status)"
    echo "$status_file"; [[ "$status_file" = *'Enable failed'* ]]
}

@test "handler command: enable - validates json schema" {
    mk_container sh -c "fake-waagent install && fake-waagent enable"
    push_settings '{"badElement":null, "commandToExecute":"date"}' ''
   
    run start_container
    echo "$output"
    [ "$status" -eq 1 ]
    [[ "$output" == *"json validation error: invalid public settings JSON: badElement"* ]]
}


@test "handler command: enable - captures stdout/stderr into file" {
    mk_container sh -c "fake-waagent install && fake-waagent enable"
    push_settings '
    {
        "commandToExecute": "echo HelloStdout>&1; echo HelloStderr>&2"
    }' ''
    run start_container
    echo "$output"
    [ "$status" -eq 0 ]

    # Validate contents of stdout/stderr files
    stdout="$(container_read_file /var/lib/azure/custom-script/download/0/stdout)"
    echo "stdout=$stdout" && [[ "$stdout" = "HelloStdout" ]]
    stderr="$(container_read_file /var/lib/azure/custom-script/download/0/stderr)"
    echo "stderr=$stderr" && [[ "$stderr" = "HelloStderr" ]]
}

@test "handler command: enable - doesn't process the same sequence number again" {
    mk_container sh -c \
        "fake-waagent install && fake-waagent enable && fake-waagent enable"
    push_settings '{"commandToExecute": "date"}' ''
   
    run start_container
    echo "$output"
    [ "$status" -eq 0 ]
    enable_count="$(echo "$output" | grep -c 'event=enabled')"
    echo "Enable count=$enable_count"
    [ "$enable_count" -eq 1 ]
    [[ "$output" == *"this script configuration is already processed, will not run again"* ]] # not processed again
}

@test "handler command: enable - parses protected settings" {
    mk_container sh -c "fake-waagent install && fake-waagent enable"
    push_settings ''  '{"commandToExecute":"touch /a.txt"}'
    run start_container
    echo "$output"
    [ "$status" -eq 0 ]

    diff="$(container_diff)"; echo "$diff"
    [[ "$diff" == *"A /a.txt"* ]]
}

@test "handler command: enable - downloads files" {
    mk_container sh -c "fake-waagent install && fake-waagent enable"
    # download an external script and run it
    push_settings '{
        "fileUris": [
                "https://gist.github.com/anonymous/8c83af2923ec8dd4a92309594a6c90d7/raw/f26c2cbf68e22d42f703b78f8a4562c5c8e43ba7/script.sh"
        ],
        "commandToExecute":"./script.sh"
        }'
    run start_container
    echo "$output"
    [ "$status" -eq 0 ]

    diff="$(container_diff)"; echo "$diff"
    [[ "$diff" == *"A /var/lib/azure/custom-script/download/0/script.sh"* ]] # file downloaded
    [[ "$diff" == *"A /b.txt"* ]] # created by script.sh
}

@test "handler command: enable - download files from storage account" {
    if [[ -z  "$AZURE_STORAGE_ACCOUNT" ]] || [[ -z  "$AZURE_STORAGE_ACCESS_KEY" ]]; then
        skip "AZURE_STORAGE_ACCOUNT or AZURE_STORAGE_ACCESS_KEY not specified"
    fi

    # make random file
    tmp="$(mktemp)"
    dd if=/dev/urandom of="$tmp" bs=1k count=512

    # upload files to a storage container
    cnt="testcontainer"
    blob1="blob1-$RANDOM"
    blob2="blob2-$RANDOM"
    azure storage container show  "$cnt" 1>/dev/null ||
        azure storage container create "$cnt" 1>/dev/null && echo "Azure Storage container created">&2
    azure storage blob upload -f "$tmp" "$cnt" "$blob1" 1>/dev/null  # upload blob1
    azure storage blob upload -f "$tmp" "$cnt" "$blob2" 1>/dev/null # upload blob2

    blob1_url="http://$AZURE_STORAGE_ACCOUNT.blob.core.windows.net/$cnt/$blob1" # over http
    blob2_url="https://$AZURE_STORAGE_ACCOUNT.blob.core.windows.net/$cnt/$blob2" # over https

    mk_container sh -c "fake-waagent install && fake-waagent enable && wait-for-enable" # add sleep for enable to finish in the background
    # download an external script and run it
    push_settings "{
        \"fileUris\": [
                \"$blob1_url\",
                \"$blob2_url\"
        ],
        \"commandToExecute\":\"date\"
        }" "{
            \"storageAccountName\": \"$AZURE_STORAGE_ACCOUNT\",
            \"storageAccountKey\": \"$AZURE_STORAGE_ACCESS_KEY\"
        }"
    run start_container
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *'file=0 event="download complete"'* ]]
    [[ "$output" == *'file=1 event="download complete"'* ]]

    diff="$(container_diff)"; echo "$diff"
    [[ "$diff" == *"A /var/lib/azure/custom-script/download/0/$blob1"* ]] # file downloaded
    [[ "$diff" == *"A /var/lib/azure/custom-script/download/0/$blob2"* ]] # file downloaded

    # compare checksum
    existing=$(cat "$tmp" | md5 -q)
    echo "Local file checksum: $existing"
    got=$(container_read_file "/var/lib/azure/custom-script/download/0/$blob1" | md5 -q)
    echo "Downloaded file checksum: $got"
    [[ "$existing" == "$got" ]]
}

@test "handler command: uninstall - deletes the data dir" {
    run in_container sh -c \
        "fake-waagent install && fake-waagent uninstall"
    echo "$output"
    [ "$status" -eq 0 ]

    echo "$output"; [ "$status" -eq 0 ]
    diff="$(container_diff)" && echo "$diff"
    [[ "$diff" != */var/lib/azure/custom-script* ]]
}

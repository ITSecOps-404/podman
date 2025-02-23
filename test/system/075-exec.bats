#!/usr/bin/env bats   -*- bats -*-
#
# Tests for podman exec
#

load helpers

# bats test_tags=distro-integration
@test "podman exec - basic test" {
    rand_filename=$(random_string 20)
    rand_content=$(random_string 50)

    # Start a container. Write random content to random file, then stay
    # alive as long as file exists. (This test will remove that file soon.)
    run_podman run -d $IMAGE sh -c \
               "echo $rand_content >/$rand_filename;echo READY;while [ -f /$rand_filename ]; do sleep 1; done"
    cid="$output"
    wait_for_ready $cid

    run_podman exec $cid sh -c "cat /$rand_filename"
    is "$output" "$rand_content" "Can exec and see file in running container"


    # Specially defined situations: exec a dir, or no such command.
    # We don't check the full error message because runc & crun differ.
    #
    # UPDATE 2023-07-17 runc on RHEL8 (but not Debian) now says "is a dir"
    # and exits 255 instead of 126 as it does everywhere else.
    run_podman '?' exec $cid /etc
    is "$output" ".*\(permission denied\|is a directory\)"  \
       "podman exec /etc"
    assert "$status" -ne 0 "exit status from 'exec /etc'"
    run_podman 127 exec $cid /no/such/command
    is "$output" ".*such file or dir"   "podman exec /no/such/command"

    # Done. Tell the container to stop.
    # The '-d' is because container exit is racy: the exec process itself
    # could get caught and killed by cleanup, causing this step to exit 137
    run_podman exec -d $cid rm -f /$rand_filename

    run_podman wait $cid
    is "$output" "0"   "output from podman wait (container exit code)"

    run_podman rm $cid
}

# bats test_tags=distro-integration
@test "podman exec - leak check" {
    skip_if_remote "test is meaningless over remote"

    # Start a container in the background then run exec command
    # three times and make sure no any exec pid hash file leak
    run_podman run -td $IMAGE /bin/sh
    cid="$output"

    is "$(check_exec_pid)" "" "exec pid hash file indeed doesn't exist"

    for i in {1..3}; do
        run_podman exec $cid /bin/true
    done

    is "$(check_exec_pid)" "" "there isn't any exec pid hash file leak"

    run_podman rm -t 0 -f $cid
}

# Issue #4785 - piping to exec statement - fixed in #4818
# Issue #5046 - piping to exec truncates results (actually a conmon issue)
@test "podman exec - cat from stdin" {
    run_podman run -d $IMAGE top
    cid="$output"

    echo_string=$(random_string 20)
    run_podman exec -i $cid cat < <(echo $echo_string)
    is "$output" "$echo_string" "output read back from 'exec cat'"

    # #5046 - large file content gets lost via exec
    # Generate a large file with random content; get a hash of its content
    local bigfile=${PODMAN_TMPDIR}/bigfile
    dd if=/dev/urandom of=$bigfile bs=1024 count=1500
    expect=$(sha512sum $bigfile | awk '{print $1}')
    # Transfer it to container, via exec, make sure correct #bytes are sent
    run_podman exec -i $cid dd of=/tmp/bigfile bs=512 <$bigfile
    is "${lines[0]}" "3000+0 records in"  "dd: number of records in"
    is "${lines[1]}" "3000+0 records out" "dd: number of records out"
    # Verify sha. '% *' strips off the path, keeping only the SHA
    run_podman exec $cid sha512sum /tmp/bigfile
    is "${output% *}" "$expect " "SHA of file in container"

    # Clean up
    run_podman rm -f -t0 $cid
}

# #6829 : add username to /etc/passwd inside container if --userns=keep-id
@test "podman exec - with keep-id" {
    skip_if_not_rootless "--userns=keep-id only works in rootless mode"
    # Multiple --userns options confirm command-line override (last one wins)
    run_podman run -d --userns=private --userns=keep-id $IMAGE sh -c 'echo READY;top'
    cid="$output"
    wait_for_ready $cid

    run_podman exec $cid id -un
    is "$output" "$(id -un)" "container is running as current user"

    run_podman rm -f -t0 $cid
}

# #11496: podman-remote loses output
@test "podman exec/run - missing output" {
    local bigfile=${PODMAN_TMPDIR}/bigfile
    local newfile=${PODMAN_TMPDIR}/newfile
    # create a big file, bigger than the 8K buffer size
    base64 /dev/urandom | head -c 20K > $bigfile

    run_podman run --rm -v $bigfile:/tmp/test:Z $IMAGE cat /tmp/test
    printf "%s" "$output" > $newfile
    # use cmp to compare the files, this is very helpful since it will
    # tell us the first wrong byte in case this fails
    run cmp $bigfile $newfile
    is "$output" "" "run output is identical with the file"

    run_podman run -d --stop-timeout 0 -v $bigfile:/tmp/test:Z $IMAGE sleep inf
    cid="$output"

    run_podman exec $cid cat /tmp/test
    printf "%s" "$output" > $newfile
    # use cmp to compare the files, this is very helpful since it will
    # tell us the first wrong byte in case this fails
    run cmp $bigfile $newfile
    is "$output" "" "exec output is identical with the file"

    # Clean up
    run_podman rm -t 0 -f $cid
}

@test "podman exec --wait" {
    skip_if_remote "test is meaningless over remote"

    # wait on bogus container
    run_podman 125 exec --wait 5 "bogus_container" echo hello
    assert "$output" = "Error: timed out waiting for container: bogus_container"

    run_podman create --name "wait_container" $IMAGE top
    run_podman 255 exec --wait 5 "wait_container" echo hello
    assert "$output" = "Error: can only create exec sessions on running containers: container state improper"

    run_podman rm -f wait_container
}

@test "podman run umask" {
    test "$(podman_runtime)" == "crun" \
        || skip "FIXME: runtime is $(podman_runtime); this test requires crun or runc 1.1.7 or newer which is not currently in debian"
    umask="0724"
    run_podman run --rm -q $IMAGE grep Umask /proc/self/status
    is "$output" "Umask:.*0022" "default_umask should not be modified"

    run_podman run -q --rm --umask $umask $IMAGE grep Umask /proc/self/status
    is "$output" "Umask:.*$umask" "umask should be modified"
    run_podman run -q -d --umask $umask $IMAGE sleep inf
    cid=$output
    run_podman exec $cid grep Umask /proc/self/status
    is "$output" "Umask:.*$umask" "exec umask should match container umask"
    run_podman exec $cid sh -c "touch /foo; stat -c '%a' /foo"
    is "$output" "42" "umask should apply to newly created file"

    run_podman rm -f -t0 $cid
}

@test "podman exec --tty" {
    # Outer loops: different variations on the RUN container
    for run_opt_t in "" "-t"; do
        for run_term_env in "" "explicit_RUN_term"; do
            local run_opt_env=
            if [[ -n "$run_term_env" ]]; then
                run_opt_env="--env=TERM=$run_term_env"
            fi
            run_podman run -d $run_opt_t $run_opt_env --name test $IMAGE top

            # Inner loops: different variations on EXEC
            for exec_opt_t in "" "-t"; do
                for exec_term_env in "" "explicit_EXEC_term"; do
                    # What to expect.
                    local expected=
                    # if -t is set anywhere, either run or exec, go with xterm
                    if [[ -n "$run_opt_t$exec_opt_t" ]]; then
                        expected="xterm"
                    fi
                    # ...unless overridden by explicit --env
                    if [[ -n "$run_term_env$exec_term_env" ]]; then
                        # (exec overrides run)
                        expected="${exec_term_env:-$run_term_env}"
                    fi

                    local exec_opt_env=
                    if [[ -n "$exec_term_env" ]]; then
                        exec_opt_env="--env=TERM=$exec_term_env"
                    fi

                    local desc="run $run_opt_t $run_opt_env, exec $exec_opt_t $exec_opt_env"
                    TERM=exec-term run_podman exec $exec_opt_t $exec_opt_env test sh -c 'echo -n $TERM'
                    assert "$output" = "$expected" "$desc"
                done
            done

            run_podman rm -f -t0 test
        done
    done
}

@test "podman exec - does not leak session IDs on invalid command" {
    skip_if_remote "FIXME FIXME FIXME: this should work on remote, but does not"
    run_podman run -d $IMAGE top
    cid="$output"

    for i in {1..3}; do
        run_podman 127 exec $cid blahblah
        run_podman 125 exec -d $cid blahblah
    done

    run_podman inspect --format "{{len .ExecIDs}}" $cid
    assert "$output" = "0" ".ExecIDs must be empty"
}

# vim: filetype=sh

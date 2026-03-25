#!/bin/bash
###############################################################################
#  ENM Health Check Script - All 8 Servers
#  ----------------------------------------
#  Version : 5.0  (2026-03-25)
#
#  Purpose : SSH into each ENM server, run the Ericsson health-check command,
#            collect individual logs, and produce a single summary report
#            highlighting every error / failure found.
#
#  Deploy  : /home/eric/scripts/ajiteguh/enm_healthcheck.sh
#  Output  : /home/eric/scripts/ajiteguh/output_healthcheck/
#  Summary : /home/eric/scripts/ajiteguh/output_healthcheck/summary/
#
#  Usage   :
#    ./enm_healthcheck.sh              # Interactive menu (pick servers)
#    ./enm_healthcheck.sh --all        # All servers (for cronjob)
#    ./enm_healthcheck.sh ENMR1        # Single server
#    ./enm_healthcheck.sh ENMR1 ENMR4  # Multiple servers
#    ./enm_healthcheck.sh --list       # Show available servers
#
#  Cron    :
#    0 5 * * * /home/eric/scripts/ajiteguh/enm_healthcheck.sh --all >> /home/eric/scripts/ajiteguh/output_healthcheck/cron.log 2>&1
#
#  Cleanup :
#    The script automatically deletes the following files older than 7 days:
#      - Server log files   : /home/eric/scripts/ajiteguh/output_healthcheck/*.log
#      - Summary files      : /home/eric/scripts/ajiteguh/output_healthcheck/summary/*.log
#      - Cron log file      : /home/eric/scripts/ajiteguh/output_healthcheck/cron.log
#      - Temp expect files  : /home/eric/scripts/ajiteguh/output_healthcheck/.expect_*.exp
#
#  NOTE    : Replace "password123" with the real password for each server.
#            This script uses 'expect' (usually pre-installed) to handle
#            password-based SSH.  No additional packages are installed.
###############################################################################

SCRIPT_VERSION="5.0"

# ========================== CONFIGURATION ====================================

# Base directories
SCRIPT_DIR="/home/eric/scripts/ajiteguh"
OUTPUT_DIR="${SCRIPT_DIR}/output_healthcheck"
SUMMARY_DIR="${OUTPUT_DIR}/summary"

# Health-check command executed on each remote server
HC_CMD="/opt/ericsson/enminst/bin/enm_healthcheck.sh --action enminst_healthcheck"

# SSH options
#   - StrictHostKeyChecking=no    : skip host-key prompts
#   - UserKnownHostsFile=/dev/null: don't pollute known_hosts
#   - ConnectTimeout=30           : fail fast if server unreachable
#   - ServerAliveInterval=60      : send keepalive every 60s to prevent drops
#   - ServerAliveCountMax=120     : allow up to 120 missed keepalives (2 hours)
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o ServerAliveInterval=60 -o ServerAliveCountMax=120"

# Maximum time (seconds) allowed per server health check (2 hours)
PER_SERVER_TIMEOUT=7200

# Number of days to keep log files before auto-deletion
RETENTION_DAYS=7

# Unique marker to detect when the remote command finishes
SENTINEL="__ENM_HC_DONE_SENTINEL__"

# Timestamp used for every log file in this run (ensures they all match)
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
HUMAN_DATE="$(date '+%d %B %Y')"   # e.g. "25 March 2026"

# ---- Server list ----
# Format: NAME|USER|PASSWORD|IP
ALL_SERVERS=(
    "ENMR1|root|password123|10.21.233.4"
    "ENMR2|root|password123|10.26.14.11"
    "ENMR3|root|password123|10.26.16.11"
    "ENMR4|root|password123|10.26.18.11"
    "ENMJ1|root|password123|172.20.126.134"
    "ENMJ2|root|password123|10.26.20.11"
    "ENMTX|root|password123|10.26.22.11"
    "ENMCORE|root|password123|10.21.73.106"
)

# This array holds the servers selected for this run
SELECTED_SERVERS=()

# ========================== FUNCTIONS ========================================

create_directories() {
    mkdir -p "${OUTPUT_DIR}"
    mkdir -p "${SUMMARY_DIR}"
}

# ---------------------------------------------------------------------------
#  print_header / print_server_list  –  display helpers
# ---------------------------------------------------------------------------
print_header() {
    echo ""
    echo "###################################################################"
    echo "#                                                                 #"
    echo "#         ENM HEALTH CHECK TOOL - Ericsson Network Manager        #"
    echo "#         Script Version: ${SCRIPT_VERSION}                                    #"
    echo "#                                                                 #"
    echo "###################################################################"
    echo "#  Date : ${HUMAN_DATE}                                            "
    echo "#  Time : $(date '+%H:%M:%S')                                      "
    echo "###################################################################"
    echo ""
}

print_server_list() {
    echo "  Available ENM Servers:"
    echo "  ──────────────────────────────────────────"
    local idx=1
    for entry in "${ALL_SERVERS[@]}"; do
        IFS='|' read -r name user pass ip <<< "${entry}"
        printf "    %d)  %-10s  %s\n" "${idx}" "${name}" "${ip}"
        idx=$((idx + 1))
    done
    echo "  ──────────────────────────────────────────"
    echo "    A)  ALL servers"
    echo "    Q)  Quit"
    echo "  ──────────────────────────────────────────"
}

# ---------------------------------------------------------------------------
#  show_usage  –  help text
# ---------------------------------------------------------------------------
show_usage() {
    echo "Usage: $(basename "$0") [OPTIONS] [SERVER_NAME ...]"
    echo ""
    echo "Options:"
    echo "  --all         Run health check on ALL servers (for cronjob)"
    echo "  --list        List available servers and exit"
    echo "  --help, -h    Show this help message"
    echo "  --version     Show script version"
    echo ""
    echo "Examples:"
    echo "  $(basename "$0")                     # Interactive menu"
    echo "  $(basename "$0") --all               # All servers (cronjob mode)"
    echo "  $(basename "$0") ENMR1               # Single server"
    echo "  $(basename "$0") ENMR1 ENMR4 ENMCORE # Multiple servers"
    echo ""
}

# ---------------------------------------------------------------------------
#  find_server_by_name  –  lookup a server entry by name (case-insensitive)
#  Returns the full entry string or empty
# ---------------------------------------------------------------------------
find_server_by_name() {
    local search="${1^^}"   # uppercase
    for entry in "${ALL_SERVERS[@]}"; do
        IFS='|' read -r name user pass ip <<< "${entry}"
        if [ "${name^^}" = "${search}" ]; then
            echo "${entry}"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
#  interactive_menu  –  let the user pick which servers to check
# ---------------------------------------------------------------------------
interactive_menu() {
    print_header
    print_server_list
    echo ""
    echo "  Enter your choice:"
    echo "    - A single number        (e.g. 1)"
    echo "    - Multiple numbers       (e.g. 1 3 5)"
    echo "    - Server name(s)         (e.g. ENMR1 ENMR4)"
    echo "    - 'A' or 'all' for ALL servers"
    echo "    - 'Q' or 'quit' to exit"
    echo ""
    printf "  >> "
    read -r user_input

    # Trim whitespace
    user_input="$(echo "${user_input}" | xargs)"

    if [ -z "${user_input}" ]; then
        echo ""
        echo "  [!] No selection made. Exiting."
        exit 0
    fi

    # Quit
    if [[ "${user_input,,}" =~ ^(q|quit|exit)$ ]]; then
        echo ""
        echo "  Bye!"
        exit 0
    fi

    # All
    if [[ "${user_input,,}" =~ ^(a|all)$ ]]; then
        SELECTED_SERVERS=("${ALL_SERVERS[@]}")
        echo ""
        echo "  [*] Selected: ALL servers (${#ALL_SERVERS[@]})"
        return
    fi

    # Parse input tokens (could be numbers or names)
    local found=0
    for token in ${user_input}; do
        # Check if it's a number (index)
        if [[ "${token}" =~ ^[0-9]+$ ]]; then
            local idx="${token}"
            if [ "${idx}" -ge 1 ] && [ "${idx}" -le "${#ALL_SERVERS[@]}" ]; then
                SELECTED_SERVERS+=("${ALL_SERVERS[$((idx - 1))]}")
                found=$((found + 1))
            else
                echo "  [!] Invalid number: ${idx}  (valid range: 1-${#ALL_SERVERS[@]})"
            fi
        else
            # Treat as server name
            local match
            if match=$(find_server_by_name "${token}"); then
                SELECTED_SERVERS+=("${match}")
                found=$((found + 1))
            else
                echo "  [!] Unknown server: ${token}"
            fi
        fi
    done

    if [ "${found}" -eq 0 ]; then
        echo ""
        echo "  [!] No valid servers selected. Exiting."
        exit 1
    fi

    echo ""
    echo "  [*] Selected ${found} server(s):"
    for entry in "${SELECTED_SERVERS[@]}"; do
        IFS='|' read -r name user pass ip <<< "${entry}"
        echo "       - ${name} (${ip})"
    done
}

# ---------------------------------------------------------------------------
#  run_healthcheck  –  SSH into a server via expect and capture the output
#  Args: $1=name  $2=user  $3=password  $4=ip
#
#  Approach:
#    1. expect spawns interactive SSH (-tt)
#    2. Waits ONLY for "password:" prompt — sends password
#    3. After password, sleeps 5s to let shell fully initialize
#       (NO prompt detection — avoids # in banners being misread)
#    4. Sends the healthcheck command + sentinel echo
#    5. Waits for sentinel string (up to 2 hours)
#    6. Entire run is wrapped in bash 'timeout' command so one
#       stuck server cannot block the rest
# ---------------------------------------------------------------------------
run_healthcheck() {
    local name="$1" user="$2" pass="$3" ip="$4"
    local logfile="${OUTPUT_DIR}/${name}_${TIMESTAMP}.log"

    echo ""
    echo "=========================================================="
    echo " [$(date '+%H:%M:%S')]  Starting health check on ${name} (${ip})"
    echo "  Script version: ${SCRIPT_VERSION}"
    echo "  Max timeout: ${PER_SERVER_TIMEOUT}s ($(( PER_SERVER_TIMEOUT / 3600 ))h)"
    echo "=========================================================="

    # Create the expect script in a temp file
    local expect_script="${OUTPUT_DIR}/.expect_${name}_$$.exp"
    cat > "${expect_script}" <<'EXPECT_TEMPLATE'
# --- Parameters passed via environment ---
set srv_name    $env(HC_SERVER_NAME)
set srv_user    $env(HC_SERVER_USER)
set srv_pass    $env(HC_SERVER_PASS)
set srv_ip      $env(HC_SERVER_IP)
set ssh_opts    $env(HC_SSH_OPTS)
set hc_cmd      $env(HC_CMD)
set sentinel    $env(HC_SENTINEL)
set logfile     $env(HC_LOGFILE)

# --- Logging ---
log_file -noappend $logfile
log_user 1

# --- Phase 1: Connect and authenticate ---
# Timeout for the connection + password phase only
set timeout 120
spawn ssh -tt {*}$ssh_opts $srv_user@$srv_ip

# Wait for the password prompt — this is the ONLY thing we look for.
# We do NOT try to detect the shell prompt (# or $) because server
# banners (like ENMJ1's ### WARNING ###) contain # characters that
# cause false matches.
expect {
    -re "assword:" {
        send "$srv_pass\r"
    }
    -re "yes/no" {
        send "yes\r"
        exp_continue
    }
    timeout {
        puts "\n>>> ERROR: Could not reach password prompt on $srv_name ($srv_ip) within 120 seconds. <<<"
        exit 1
    }
    eof {
        puts "\n>>> ERROR: Connection to $srv_name ($srv_ip) closed before login. <<<"
        exit 1
    }
}

# --- Phase 2: Wait for shell to be ready ---
# Sleep to let the shell fully initialize after password.
# This avoids any banner/MOTD with # or $ being misread as a prompt.
sleep 5

# --- Phase 3: Run healthcheck (2-hour timeout) ---
set timeout 7200
send "$hc_cmd ; echo $sentinel\r"

expect {
    "$sentinel" {
        # Health check command completed successfully
    }
    timeout {
        puts "\n>>> TIMEOUT: Health check on $srv_name ($srv_ip) did not complete within 2 hours. <<<"
        send "\x03"
        sleep 2
        send "exit\r"
        expect eof
        exit 1
    }
    eof {
        puts "\n>>> ERROR: Connection to $srv_name ($srv_ip) dropped during health check. <<<"
        exit 1
    }
}

# --- Phase 4: Clean exit ---
send "exit\r"
expect eof
exit 0
EXPECT_TEMPLATE

    # Export variables for the expect script
    export HC_SERVER_NAME="${name}"
    export HC_SERVER_USER="${user}"
    export HC_SERVER_PASS="${pass}"
    export HC_SERVER_IP="${ip}"
    export HC_SSH_OPTS="${SSH_OPTS}"
    export HC_CMD="${HC_CMD}"
    export HC_SENTINEL="${SENTINEL}"
    export HC_LOGFILE="${logfile}"

    # Run expect inside 'timeout' so one stuck server can't block the rest.
    # timeout sends SIGTERM after PER_SERVER_TIMEOUT, then SIGKILL 30s later.
    timeout --signal=TERM --kill-after=30 "${PER_SERVER_TIMEOUT}" \
        /usr/bin/expect "${expect_script}" 2>&1 | tee "${logfile}.screen"
    local rc=$?

    # Remove temp expect script
    rm -f "${expect_script}"

    # Handle timeout exit code (124 = timed out by 'timeout' command)
    if [ ${rc} -eq 124 ]; then
        echo ">>> TIMEOUT: Health check on ${name} was killed after ${PER_SERVER_TIMEOUT}s by safety timeout." | tee -a "${logfile}"
    elif [ ${rc} -ne 0 ]; then
        echo ">>> WARNING: Health check on ${name} exited with code ${rc}" | tee -a "${logfile}"
    fi

    # Clean the log file: remove sentinel lines, carriage returns, expect noise
    if [ -f "${logfile}" ]; then
        sed -i "/${SENTINEL}/d" "${logfile}" 2>/dev/null || true
        sed -i 's/\r//g' "${logfile}" 2>/dev/null || true
    fi

    # Fallback: if expect log_file didn't capture but tee did, use the screen copy
    if [ ! -s "${logfile}" ] && [ -s "${logfile}.screen" ]; then
        sed "/${SENTINEL}/d" "${logfile}.screen" | sed 's/\r//g' > "${logfile}"
    fi
    rm -f "${logfile}.screen"

    echo ""
    echo "──────────────────────────────────────────────────────────────"
    echo " [$(date '+%H:%M:%S')]  Finished ${name}"
    echo " Log saved : ${logfile}"
    echo " Log size  : $(du -h "${logfile}" 2>/dev/null | cut -f1)"
    echo " Exit code : ${rc}"
    echo "──────────────────────────────────────────────────────────────"
    echo ""
}

# ---------------------------------------------------------------------------
#  generate_summary  –  Parse each log for errors/failures, write one report
# ---------------------------------------------------------------------------
generate_summary() {
    local summary_file="${SUMMARY_DIR}/Summary_${TIMESTAMP}.log"

    echo ""
    echo "###################################################################"
    echo "#  Generating Summary Report..."
    echo "###################################################################"
    echo ""

    {
        echo "╔══════════════════════════════════════════════════════════════════════════╗"
        echo "║                                                                        ║"
        echo "║     SUMMARY OF HEALTHCHECK - ENM SERVERS ON ${HUMAN_DATE}              ║"
        echo "║                                                                        ║"
        echo "╠══════════════════════════════════════════════════════════════════════════╣"
        echo "║  Generated  : $(date '+%Y-%m-%d %H:%M:%S')                                          ║"
        echo "║  Script Ver : ${SCRIPT_VERSION}                                                      ║"
        echo "║  Log Dir    : ${OUTPUT_DIR}"
        echo "║  Servers    : ${#SELECTED_SERVERS[@]} checked                                        ║"
        echo "╚══════════════════════════════════════════════════════════════════════════╝"
        echo ""

        local total_ok=0
        local total_fail=0

        for entry in "${SELECTED_SERVERS[@]}"; do
            IFS='|' read -r name user pass ip <<< "${entry}"
            local logfile="${OUTPUT_DIR}/${name}_${TIMESTAMP}.log"

            echo "┌──────────────────────────────────────────────────────────────────────────┐"
            echo "│  Server : ${name}  (${ip})"
            echo "│  File   : ${name}_${TIMESTAMP}.log"
            echo "├──────────────────────────────────────────────────────────────────────────┤"

            if [ ! -f "${logfile}" ]; then
                echo "│"
                echo "│  [WARNING] Log file not found — health check may not have run."
                echo "│"
                echo "└──────────────────────────────────────────────────────────────────────────┘"
                echo ""
                total_fail=$((total_fail + 1))
                continue
            fi

            # Check if log file is empty
            if [ ! -s "${logfile}" ]; then
                echo "│"
                echo "│  [WARNING] Log file is empty — health check produced no output."
                echo "│            Possible causes: SSH connection failed, server unreachable,"
                echo "│            or authentication error."
                echo "│"
                echo "└──────────────────────────────────────────────────────────────────────────┘"
                echo ""
                total_fail=$((total_fail + 1))
                continue
            fi

            # Grep for error / failure lines (case-insensitive)
            # Exclude: spawn/ssh lines, password prompts, zero-count lines,
            #          SSH warnings, sentinel, authorized-use banners
            local issues=""
            issues=$(grep -i -E "error|fail|critical|unable|exception|refused|unreachable|not found|denied|fatal" "${logfile}" \
                     | grep -v -i -E "^spawn |ConnectTimeout|StrictHostKeyChecking|UserKnownHostsFile|ServerAliveInterval|ServerAliveCountMax|0 error|0 fail|no error|no fail|errors: 0|failures: 0|error_count.*0|fail_count.*0|password:|Warning: Permanently added|authorized use|SENTINEL" \
                     || true)

            if [ -z "${issues}" ]; then
                echo "│"
                echo "│  [OK] No errors and failures found."
                echo "│"
                total_ok=$((total_ok + 1))
            else
                local issue_count
                issue_count=$(echo "${issues}" | wc -l)
                echo "│"
                echo "│  [ISSUES] ${issue_count} error/failure line(s) detected:"
                echo "│"
                while IFS= read -r line; do
                    # Trim long lines to keep summary readable
                    if [ ${#line} -gt 100 ]; then
                        echo "│     ${line:0:100}..."
                    else
                        echo "│     ${line}"
                    fi
                done <<< "${issues}"
                echo "│"
                total_fail=$((total_fail + 1))
            fi

            echo "└──────────────────────────────────────────────────────────────────────────┘"
            echo ""
        done

        echo "╔══════════════════════════════════════════════════════════════════════════╗"
        echo "║  TOTALS                                                                ║"
        echo "╠══════════════════════════════════════════════════════════════════════════╣"
        echo "║  Servers checked  : ${#SELECTED_SERVERS[@]}"
        echo "║  Healthy (OK)     : ${total_ok}"
        echo "║  With issues      : ${total_fail}"
        echo "╚══════════════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "══════════════════════════════════════════════════════════════════════════"
        echo "  END OF SUMMARY"
        echo "══════════════════════════════════════════════════════════════════════════"

    } | tee "${summary_file}"

    echo ""
    echo "###################################################################"
    echo "#  Summary saved to: ${summary_file}"
    echo "###################################################################"
    echo ""
}

# ---------------------------------------------------------------------------
#  cleanup_old_files  –  Remove logs & summaries older than RETENTION_DAYS
#
#  Cleans up:
#    1. Server health check logs  : output_healthcheck/*.log
#    2. Summary report files      : output_healthcheck/summary/*.log
#    3. Cron console log          : output_healthcheck/cron.log (truncated)
#    4. Leftover temp expect files: output_healthcheck/.expect_*.exp
# ---------------------------------------------------------------------------
cleanup_old_files() {
    echo ""
    echo "[$(date '+%H:%M:%S')]  Cleaning up files older than ${RETENTION_DAYS} days..."

    # 1. Delete server log files older than RETENTION_DAYS
    local deleted_logs
    deleted_logs=$(find "${OUTPUT_DIR}" -maxdepth 1 -name "ENM*.log" -type f -mtime +${RETENTION_DAYS} -print -delete 2>/dev/null | wc -l)
    echo "  - Deleted ${deleted_logs} server log file(s) from ${OUTPUT_DIR}"

    # 2. Delete summary files older than RETENTION_DAYS
    local deleted_summaries
    deleted_summaries=$(find "${SUMMARY_DIR}" -name "Summary_*.log" -type f -mtime +${RETENTION_DAYS} -print -delete 2>/dev/null | wc -l)
    echo "  - Deleted ${deleted_summaries} summary file(s) from ${SUMMARY_DIR}"

    # 3. Truncate cron.log if it is older than RETENTION_DAYS
    #    (cron.log is a single appended file, so we truncate instead of delete)
    local cron_log="${OUTPUT_DIR}/cron.log"
    if [ -f "${cron_log}" ]; then
        local cron_age_days
        cron_age_days=$(( ( $(date +%s) - $(stat -c %Y "${cron_log}" 2>/dev/null || echo "0") ) / 86400 ))
        local cron_size
        cron_size=$(du -h "${cron_log}" 2>/dev/null | cut -f1)
        if [ "${cron_age_days}" -gt "${RETENTION_DAYS}" ]; then
            > "${cron_log}"
            echo "  - Truncated cron.log (was ${cron_size}, ${cron_age_days} days old)"
        else
            echo "  - cron.log: ${cron_size}, ${cron_age_days} day(s) old — kept"
        fi
    fi

    # 4. Remove any leftover temp expect scripts
    local deleted_tmp
    deleted_tmp=$(find "${OUTPUT_DIR}" -maxdepth 1 -name ".expect_*.exp" -type f -print -delete 2>/dev/null | wc -l)
    if [ "${deleted_tmp}" -gt 0 ]; then
        echo "  - Deleted ${deleted_tmp} leftover temp expect script(s)"
    fi

    echo "[$(date '+%H:%M:%S')]  Cleanup done."
}

# ========================== ARGUMENT PARSING =================================

parse_arguments() {
    # No arguments → interactive menu
    if [ $# -eq 0 ]; then
        interactive_menu
        return
    fi

    case "$1" in
        --help|-h)
            show_usage
            exit 0
            ;;
        --list)
            print_header
            print_server_list
            exit 0
            ;;
        --version)
            echo "ENM Health Check Script v${SCRIPT_VERSION}"
            exit 0
            ;;
        --all)
            SELECTED_SERVERS=("${ALL_SERVERS[@]}")
            echo ""
            echo "  [*] Mode: ALL servers (${#ALL_SERVERS[@]})"
            ;;
        *)
            # Treat all arguments as server names
            for arg in "$@"; do
                local match
                if match=$(find_server_by_name "${arg}"); then
                    SELECTED_SERVERS+=("${match}")
                else
                    echo "  [!] Unknown server: ${arg}"
                    echo "      Use --list to see available servers."
                fi
            done

            if [ ${#SELECTED_SERVERS[@]} -eq 0 ]; then
                echo "  [!] No valid servers specified. Exiting."
                exit 1
            fi

            echo ""
            echo "  [*] Selected ${#SELECTED_SERVERS[@]} server(s):"
            for entry in "${SELECTED_SERVERS[@]}"; do
                IFS='|' read -r name user pass ip <<< "${entry}"
                echo "       - ${name} (${ip})"
            done
            ;;
    esac
}

# ========================== MAIN =============================================

main() {
    parse_arguments "$@"

    print_header

    create_directories

    echo "  Starting health checks on ${#SELECTED_SERVERS[@]} server(s)..."
    echo ""

    # Run health check on each selected server.
    # || true ensures we ALWAYS continue to the next server even if one fails.
    for entry in "${SELECTED_SERVERS[@]}"; do
        IFS='|' read -r name user pass ip <<< "${entry}"
        run_healthcheck "${name}" "${user}" "${pass}" "${ip}" || true
        echo "  [*] Moving to next server..."
        echo ""
    done

    # Build a single summary from all log files
    generate_summary

    # Remove logs and summaries older than RETENTION_DAYS (7 days)
    cleanup_old_files

    echo ""
    echo "###################################################################"
    echo "#  [$(date '+%H:%M:%S')]  ALL DONE"
    echo "###################################################################"
    echo ""
}

main "$@"

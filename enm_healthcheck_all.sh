#!/bin/bash
###############################################################################
#  ENM Health Check Script - All 8 Servers
#  ----------------------------------------
#  Purpose : SSH into each ENM server, run the Ericsson health-check command,
#            collect individual logs, and produce a single summary report
#            highlighting every error / failure found.
#
#  Deploy  : /home/eric/scripts/ajiteguh/enm_healthcheck_all.sh
#  Output  : /home/eric/scripts/ajiteguh/output_healthcheck/
#  Summary : /home/eric/scripts/ajiteguh/output_healthcheck/summary/
#
#  Usage   :
#    ./enm_healthcheck_all.sh              # Interactive menu (pick servers)
#    ./enm_healthcheck_all.sh --all        # All servers (for cronjob)
#    ./enm_healthcheck_all.sh ENMR1        # Single server
#    ./enm_healthcheck_all.sh ENMR1 ENMR4  # Multiple servers
#    ./enm_healthcheck_all.sh --list       # Show available servers
#
#  Cron    : 0 5 * * * /home/eric/scripts/ajiteguh/enm_healthcheck_all.sh --all
#
#  NOTE    : Replace "password123" with the real password for each server.
#            This script uses 'expect' (usually pre-installed) to handle
#            password-based SSH.  No additional packages are installed.
###############################################################################

# ========================== CONFIGURATION ====================================

# Base directories
SCRIPT_DIR="/home/eric/scripts/ajiteguh"
OUTPUT_DIR="${SCRIPT_DIR}/output_healthcheck"
SUMMARY_DIR="${OUTPUT_DIR}/summary"

# Health-check command executed on each remote server
HC_CMD="/opt/ericsson/enminst/bin/enm_healthcheck.sh --action enminst_healthcheck"

# SSH options (no host-key prompts, short timeouts to avoid hanging)
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30"

# Timestamp used for every log file in this run (ensures they all match)
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
HUMAN_DATE="$(date '+%d %B %Y')"   # e.g. "11 March 2026"

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
# ---------------------------------------------------------------------------
run_healthcheck() {
    local name="$1" user="$2" pass="$3" ip="$4"
    local logfile="${OUTPUT_DIR}/${name}_${TIMESTAMP}.log"

    echo ""
    echo "=========================================================="
    echo " [$(date '+%H:%M:%S')]  Starting health check on ${name} (${ip})"
    echo "=========================================================="

    # Use expect to automate password-based SSH
    # The output goes to the logfile AND is shown on screen via tee
    /usr/bin/expect <<EXPECT_EOF 2>&1 | tee "${logfile}"
set timeout 600
log_user 1
spawn ssh ${SSH_OPTS} ${user}@${ip} "${HC_CMD}"
expect {
    -re ".*assword:" {
        send "${pass}\r"
        exp_continue
    }
    -re ".*yes/no.*" {
        send "yes\r"
        exp_continue
    }
    timeout {
        puts "\n>>> TIMEOUT: Health check on ${name} (${ip}) did not complete within 10 minutes. <<<"
        exit 1
    }
    eof
}
catch wait result
set rc [lindex \$result 3]
if { \$rc != 0 } {
    puts "\n>>> WARNING: Remote command exited with code \$rc <<<"
}
exit \$rc
EXPECT_EOF

    local rc=$?

    if [ ${rc} -ne 0 ]; then
        echo ">>> WARNING: Health check on ${name} exited with code ${rc}" | tee -a "${logfile}"
    fi

    echo ""
    echo "──────────────────────────────────────────────────────────────"
    echo " [$(date '+%H:%M:%S')]  Finished ${name}"
    echo " Log saved : ${logfile}"
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
            local issues=""
            issues=$(grep -i -E "error|fail|critical|unable|exception|timeout|refused|unreachable|not found|denied|fatal" "${logfile}" \
                     | grep -v -i -E "0 error|0 fail|no error|no fail|errors: 0|failures: 0|error_count.*0|fail_count.*0|password:" \
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
#  cleanup_old_files  –  Remove logs & summaries older than 7 days
# ---------------------------------------------------------------------------
cleanup_old_files() {
    echo "[$(date '+%H:%M:%S')]  Cleaning up files older than 7 days..."
    find "${OUTPUT_DIR}" -maxdepth 1 -name "*.log" -type f -mtime +7 -delete 2>/dev/null || true
    find "${SUMMARY_DIR}" -name "*.log" -type f -mtime +7 -delete 2>/dev/null || true
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

    # Run health check on each selected server
    for entry in "${SELECTED_SERVERS[@]}"; do
        IFS='|' read -r name user pass ip <<< "${entry}"
        run_healthcheck "${name}" "${user}" "${pass}" "${ip}"
    done

    # Build a single summary from all log files
    generate_summary

    # Remove logs older than 7 days
    cleanup_old_files

    echo ""
    echo "###################################################################"
    echo "#  [$(date '+%H:%M:%S')]  ALL DONE"
    echo "###################################################################"
    echo ""
}

main "$@"

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
#  Cron    : 0 5 * * * /home/eric/scripts/ajiteguh/enm_healthcheck_all.sh
#
#  NOTE    : Replace "password123" with the real password for each server.
#            This script uses 'expect' (usually pre-installed) to handle
#            password-based SSH.  No additional packages are installed.
###############################################################################

# ----- Strict mode -----
set -euo pipefail

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
SERVERS=(
    "ENMR1|root|password123|10.21.233.4"
    "ENMR2|root|password123|10.26.14.11"
    "ENMR3|root|password123|10.26.16.11"
    "ENMR4|root|password123|10.26.18.11"
    "ENMJ1|root|password123|172.20.126.134"
    "ENMJ2|root|password123|10.26.20.11"
    "ENMTX|root|password123|10.26.22.11"
    "ENMCORE|root|password123|10.21.73.106"
)

# ========================== FUNCTIONS ========================================

create_directories() {
    mkdir -p "${OUTPUT_DIR}"
    mkdir -p "${SUMMARY_DIR}"
}

# ---------------------------------------------------------------------------
#  run_healthcheck  –  SSH into a server via expect and capture the output
#  Args: $1=name  $2=user  $3=password  $4=ip
# ---------------------------------------------------------------------------
run_healthcheck() {
    local name="$1" user="$2" pass="$3" ip="$4"
    local logfile="${OUTPUT_DIR}/${name}_${TIMESTAMP}.log"

    echo "=========================================================="
    echo " [$(date '+%H:%M:%S')]  Starting health check on ${name} (${ip})"
    echo "=========================================================="

    # Use expect to automate password-based SSH
    /usr/bin/expect <<EXPECT_EOF > "${logfile}" 2>&1
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
exit [lindex \$result 3]
EXPECT_EOF

    local rc=$?

    if [ ${rc} -ne 0 ]; then
        echo ">>> WARNING: Health check on ${name} exited with code ${rc}" | tee -a "${logfile}"
    fi

    echo " [$(date '+%H:%M:%S')]  Finished ${name} — log: ${logfile}"
    echo ""
}

# ---------------------------------------------------------------------------
#  generate_summary  –  Parse each log for errors/failures, write one report
# ---------------------------------------------------------------------------
generate_summary() {
    local summary_file="${SUMMARY_DIR}/Summary_${TIMESTAMP}.log"

    {
        echo "╔══════════════════════════════════════════════════════════════════════╗"
        echo "║         SUMMARY OF HEALTHCHECK - ENM SERVERS ON ${HUMAN_DATE}        ║"
        echo "╠══════════════════════════════════════════════════════════════════════╣"
        echo "║  Generated : $(date '+%Y-%m-%d %H:%M:%S')                                       ║"
        echo "║  Log Dir   : ${OUTPUT_DIR}                                          "
        echo "╚══════════════════════════════════════════════════════════════════════╝"
        echo ""

        for entry in "${SERVERS[@]}"; do
            IFS='|' read -r name user pass ip <<< "${entry}"
            local logfile="${OUTPUT_DIR}/${name}_${TIMESTAMP}.log"

            echo "┌──────────────────────────────────────────────────────────────────────┐"
            echo "│  Server : ${name}  (${ip})"
            echo "│  File   : ${name}_${TIMESTAMP}.log"
            echo "├──────────────────────────────────────────────────────────────────────┤"

            if [ ! -f "${logfile}" ]; then
                echo "│  ⚠  Log file not found — health check may not have run."
                echo "└──────────────────────────────────────────────────────────────────────┘"
                echo ""
                continue
            fi

            # Grep for error / failure lines (case-insensitive)
            local issues
            issues=$(grep -i -E "error|fail|critical|unable|exception|timeout|refused|unreachable|not found|denied|fatal" "${logfile}" \
                     | grep -v -i "0 error\|0 fail\|no error\|no fail\|error.*0\|fail.*0" \
                     || true)

            if [ -z "${issues}" ]; then
                echo "│"
                echo "│  ✔  No errors and failures found."
                echo "│"
            else
                echo "│"
                echo "│  ✘  Errors / Failures detected:"
                echo "│"
                while IFS= read -r line; do
                    echo "│     ${line}"
                done <<< "${issues}"
                echo "│"
            fi

            echo "└──────────────────────────────────────────────────────────────────────┘"
            echo ""
        done

        echo "══════════════════════════════════════════════════════════════════════"
        echo "  END OF SUMMARY"
        echo "══════════════════════════════════════════════════════════════════════"

    } > "${summary_file}"

    echo "============================================="
    echo "  Summary written to: ${summary_file}"
    echo "============================================="

    # Print summary to stdout as well (useful for cron e-mail)
    cat "${summary_file}"
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

# ========================== MAIN =============================================

main() {
    echo ""
    echo "###############################################################"
    echo "#  ENM Health Check — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "###############################################################"
    echo ""

    create_directories

    # Run health check on every server sequentially
    for entry in "${SERVERS[@]}"; do
        IFS='|' read -r name user pass ip <<< "${entry}"
        run_healthcheck "${name}" "${user}" "${pass}" "${ip}"
    done

    # Build a single summary from all log files
    generate_summary

    # Remove logs older than 7 days
    cleanup_old_files

    echo ""
    echo "[$(date '+%H:%M:%S')]  All done."
}

main "$@"

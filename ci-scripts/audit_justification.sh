#!/bin/bash

for arg; do
    case "$arg" in
        image=*)
            IMAGE="${arg#image=}"
            ;;
        -h|--help)
            echo "The following arguments are valid: "
            echo -e "\t -a|--add-justification (add justfication to be tracked)"
            echo -e "\t -c|--check-justification (check audit findings against tracked justifications)"
            echo -e "\t -u|--update-justification (update currently tracked justification)"
            echo -e "\t -d|--delete-justification (delete tracked justification)"
            echo -e "\t -v|--view-justification (view tracked justification)"
            exit 0
            ;;
    esac
done

ROOT_DIR="$( pwd )"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JUSTIFICATION_FILE="${SCRIPT_DIR}/justification.json"

AUDIT_FILE="${SCRIPT_DIR}/audit-report.json"
TMP_FILE=$(mktemp)
ARGS=("$@")

if [[ ${#ARGS[@]} -eq 0 ]]; then
    echo "This script needs an argument to run. Run with --help if unsure of what argument."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Please install it to use this script."
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is NOT installed. Please install it to use this script."
    exit 1
fi

CURRENT_HASH=$(jq -r '.hash' ${JUSTIFICATION_FILE})
jq 'del(.hash)' ${JUSTIFICATION_FILE} > ${TMP_FILE}
NEW_HASH=$(sha256sum ${TMP_FILE} | awk '{print $1}')

if [[ $CURRENT_HASH != $NEW_HASH ]]; then
    echo "Detected Justification file was tampered. Will not continue"
    rm -f ${TMP_FILE}
    exit 1
fi


check_image(){
    if [[ -z $IMAGE ]]; then
        echo "Error: missing the 'image=<image_tag>' argment"
        exit 1
    fi

    if ! docker image inspect "$IMAGE" &>/dev/null; then
        echo "Image does not exists. Building an image to scan"
        build_image
    fi
}

build_image(){
    pushd "$( mktemp --directory --tmpdir=. tmp.XXXXXX )" >/dev/null
    local PG_MAJOR=16
    local PG_VERSION="$(wget -qO- https://ftp.postgresql.org/pub/source/ | grep -oE "href=\"v$PG_MAJOR\.[0-9]+/\"" | sed -E 's/href="v(.*)\/"/\1/' | sort -V | tail -1)"
    local PG_SHA256="$(wget -qO- "https://ftp.postgresql.org/pub/source/v$PG_VERSION/postgresql-$PG_VERSION.tar.bz2.sha256" | awk '{print $1}')"
    git clone --quiet https://github.com/pgaudit/pgaudit.git
    local PGAUDIT_VERSION="$(cd pgaudit && git tag --list "${PG_MAJOR}.*" | grep -vE '(beta|rc)[0-9]*$' | sort -V | tail -1)"
    popd >/dev/null
    rm -rf "$OLDPWD"

    docker build \
        --provenance=false \
        --build-arg PG_VERSION=$PG_VERSION \
        --build-arg PG_SHA256=$PG_SHA256 \
        --build-arg PGAUDIT_VERSION=$PGAUDIT_VERSION \
        -t "$IMAGE" \
        .
}

get_audit(){
    check_image
    # Getting all critical and high vulnerabilities from trivy
    trivy image \
        --quiet \
        --exit-code 0 \
        --list-all-pkgs=false \
        --format json \
        "$IMAGE" \
        >"${ROOT_DIR}/trivy-complete-report-${PLATFORM}.json"
    if [[ $? -gt 0 ]]; then
        echo "Trivy scan failed"
        clean_up_audit_file
        exit 1
    fi

    trivy convert --format table "${ROOT_DIR}/trivy-complete-report-${PLATFORM}.json"

    jq -f "${SCRIPT_DIR}/audit_justification.jq" \
        "${ROOT_DIR}/trivy-complete-report-${PLATFORM}.json" \
        > "${AUDIT_FILE}"
    cp "${AUDIT_FILE}" "${ROOT_DIR}/audit-report-${PLATFORM}.json"
}

clean_up_audit_file(){
    rm -f ${AUDIT_FILE}
}

update_file_hash(){
    jq 'del(.hash)' ${JUSTIFICATION_FILE} > ${TMP_FILE}
    NEW_HASH=$(sha256sum ${TMP_FILE} | awk '{print $1}')
    jq --arg hash "${NEW_HASH}" '.hash = $hash' "${JUSTIFICATION_FILE}" > "${TMP_FILE}" && mv "${TMP_FILE}" "${JUSTIFICATION_FILE}"
}

add_justification(){
    # Extract unique package@range identifiers from audit file
    IFS=$'\n' read -d '' -r -a VULNS < <(jq -r '.vulnerabilities[] | .unique_finding' "$AUDIT_FILE"; printf '\0')

    echo -e "=== Adding justification for unjustified package === \n"

    if [[ ${#VULNS[@]} -eq 0 ]]; then
        echo "No vulnerabilities found in ${AUDIT_FILE}."
        clean_up_audit_file
        exit 0
    fi

    for i in "${!VULNS[@]}"; do
        if grep -q "${VULNS[$i]}" ${JUSTIFICATION_FILE}; then
            unset VULNS[$i]
        fi
    done

    VULNS=("${VULNS[@]}")

    if [[ ${#VULNS[@]} -gt 0 ]];then
        echo "Unjustified Vulnerabilities found:"
        for i in "${!VULNS[@]}"; do
            printf "%2d) %s\n" $((i+1)) "${VULNS[$i]}"
        done

        read -p "Select a vulnerability to justify: " SELECTED

        if ! [[ $SELECTED =~ ^[0-9]+$ ]] || (( SELECTED < 1 || SELECTED > ${#VULNS[@]} )); then
            echo "Invalid selection."
            clean_up_audit_file
            exit 1
        fi

        SELECTED_VULN="${VULNS[$((SELECTED-1))]}"

        echo -e "\n${SELECTED_VULN} vulnerability Info: "
        VULN_TITLE=$(jq -r --arg vuln "${SELECTED_VULN}" '.vulnerabilities[] | select(.unique_finding == $vuln) | .title' ${AUDIT_FILE})
        echo -e "\t${VULN_TITLE}"

        echo -e "\nEnter justification information: "
        read -p "Your name: " USER
        read -p "Reason for justification: " REASON

        DATE=$(date +%F)

        NEW_OBJECT=$(jq -n \
            --arg name "${SELECTED_VULN}" \
            --arg date "${DATE}" \
            --arg initiator "${USER}" \
            --arg title "${VULN_TITLE}" \
            --arg reason "${REASON}" \
            '{name: $name, date: $date, initiator: $initiator, title: $title, reason: $reason}'
        )

        # Ensure justification.json exists and is a JSON array
        if [[ ! -f $JUSTIFICATION_FILE ]]; then
            echo "{}" > "${JUSTIFICATION_FILE}"
        fi

        jq ".justifications += [${NEW_OBJECT}]" "${JUSTIFICATION_FILE}" > "${TMP_FILE}" && mv "${TMP_FILE}" "${JUSTIFICATION_FILE}"

        echo -e "\nJustification for '${SELECTED_VULN}' added to justification file."

        update_file_hash
    else
        echo "No unjustify vulnerabilities found!"
    fi
    clean_up_audit_file
}

check_for_justification(){
    IFS=$'\n' read -d '' -r -a VULNS < <(jq -r '.vulnerabilities[] | .unique_finding' "$AUDIT_FILE"; printf '\0')

    echo -e "=== Checking tracked justification for package ===\n"
    if [[ ${#VULNS[@]} -eq 0 ]]; then
        echo "No fixable, unjustified vulnerabilities found in ${AUDIT_FILE}."
        clean_up_audit_file
        exit 0
    fi

    UNJUST_VULNS=()
    OUTDATED_VULNS=()
    for i in "${!VULNS[@]}"; do
        if ! grep -q "${VULNS[$i]}" ${JUSTIFICATION_FILE}; then
            UNJUST_VULNS+=("${VULNS[$i]}")
            FAILED=true
        else
            JUSTIFICATION_DATE=$(jq -r --arg vuln "${VULNS[$i]}" '.justifications[] | select(.name == $vuln) | .date' ${JUSTIFICATION_FILE} | xargs -I{} date -d {} +%s)
            CURRENT_DATE=$(date +%s)
            DAYS_BETWEEN=$(( (CURRENT_DATE - JUSTIFICATION_DATE) / 86400 ))

            if [[ $DAYS_BETWEEN -gt 30 ]]; then
                OUTDATED_VULNS+=("${VULNS[$i]}")
                FAILED=true
            fi
        fi
    done

    if [[ ${#UNJUST_VULNS[@]} -gt 0 ]]; then
        echo "Justification(s) for the following not found: "
        printf "\t%s\n" "${UNJUST_VULNS[@]}"
    fi

    if [[ ${#OUTDATED_VULNS[@]} -gt 0 ]]; then
        echo "Justification(s) entered more then 30 days ago. Please update justification: "
        printf "\t%s\n" "- ${OUTDATED_VULNS[@]}"
    fi

    if [[ $FAILED != true ]];then
        echo "Finished checking and all vulnerabilities have been justified."
    fi
    clean_up_audit_file
}

update_justification(){
    IFS=$'\n' read -d '' -r -a VULNS < <(jq -r '.justifications[] | .name' "${JUSTIFICATION_FILE}"; printf '\0')

    echo -e "=== Updating tracked justifications === \n"

    if [[ ${#VULNS[@]} -eq 0 ]]; then
        echo "No justification found in ${JUSTIFICATION_FILE}."
        exit 0
    fi

    echo "Following justifications being tracked:"
    for i in "${!VULNS[@]}"; do
        printf "%2d) %s\n" $((i+1)) "${VULNS[$i]}"
    done

    read -p "Select a justification to update: " SELECTED

    if ! [[ $SELECTED =~ ^[0-9]+$ ]] || (( SELECTED < 1 || SELECTED > ${#VULNS[@]} )); then
        echo "Invalid selection."
        exit 1
    fi

    SELECTED_VULN="${VULNS[$((SELECTED-1))]}"

    echo -e "\nCurrent justification for ${SELECTED_VULN}:"
    echo -en "\t"
    jq -r --arg vuln "${SELECTED_VULN}" '.justifications[] | select(.name == $vuln) | .reason' "${JUSTIFICATION_FILE}"

    echo -e "\nEnter updated information: "
    read -p "Your name: " USER
    read -p "Updated justification: " JUSTIFICATION

    DATE=$(date +%F)

    jq --arg name "${SELECTED_VULN}" \
        --arg initiator "${USER}" \
        --arg justification "${JUSTIFICATION}" \
        --arg date "${DATE}" \
        '.justifications |= (map(if .name == $name then
                                    .reason = $justification |
                                    .date = $date |
                                    .initiator = $initiator else . end))' "${JUSTIFICATION_FILE}" > "${TMP_FILE}" && mv "${TMP_FILE}" "${JUSTIFICATION_FILE}"

    if [[ $? -eq 0 ]];then
        echo -e "\nJustification for ${SELECTED_VULN} updated!"
        update_file_hash
    fi
}

delete_justification(){
    IFS=$'\n' read -d '' -r -a VULNS < <(jq -r '.justifications[] | .name' "${JUSTIFICATION_FILE}"; printf '\0')

    echo -e "=== Deleting tracked justification ===\n"

    if [[ ${#VULNS[@]} -eq 0 ]]; then
        echo "No justification found in ${JUSTIFICATION_FILE}."
        exit 0
    fi

    echo "Following justifications being tracked:"
    for i in "${!VULNS[@]}"; do
        printf "%2d) %s\n" $((i+1)) "${VULNS[$i]}"
    done

    echo
    read -p "Select a justification to delete: " SELECTED

    if ! [[ $SELECTED =~ ^[0-9]+$ ]] || (( SELECTED < 1 || SELECTED > ${#VULNS[@]} )); then
        echo "Invalid selection."
        exit 1
    fi

    SELECTED_VULN="${VULNS[$((SELECTED-1))]}"

    jq --arg vuln "${SELECTED_VULN}" 'del(.justifications[] | select(.name == $vuln))' "${JUSTIFICATION_FILE}" > "${TMP_FILE}" && mv "${TMP_FILE}" "${JUSTIFICATION_FILE}"

    if [[ $? -eq 0 ]];then
        echo -e "\nJustification for ${SELECTED_VULN} was deleted"
        update_file_hash
    fi
}

view_justification(){
    IFS=$'\n' read -d '' -r -a VULNS < <(jq -r '.justifications[] | .name' "${JUSTIFICATION_FILE}"; printf '\0')

    echo -e "=== Viewing tracked justification ===\n"

    if [[ ${#VULNS[@]} -eq 0 ]]; then
        echo "No justification found in ${JUSTIFICATION_FILE}."
        exit 0
    fi

    echo "Following justifications being tracked:"
    for i in "${!VULNS[@]}"; do
        printf "%2d) %s\n" $((i+1)) "${VULNS[$i]}"
    done

    echo
    read -p "Select a vulnerability to view the justification: " SELECTED

    if ! [[ $SELECTED =~ ^[0-9]+$ ]] || (( SELECTED < 1 || SELECTED > ${#VULNS[@]} )); then
        echo "Invalid selection."
        exit 1
    fi

    SELECTED_VULN="${VULNS[$((SELECTED-1))]}"

    echo -e "\n===${SELECTED_VULN} Details ==="

    echo -e "\n Vulnerability:"
    echo -en "\t"
    jq -r --arg vuln "${SELECTED_VULN}" '.justifications[] | select(.name == $vuln) | .title' "${JUSTIFICATION_FILE}"

    echo -e "\nJustification: "
    echo -en "\t"
    jq -r --arg vuln "${SELECTED_VULN}" '.justifications[] | select(.name == $vuln) | .reason' "${JUSTIFICATION_FILE}"
}

for index in "${!ARGS[@]}"; do
    case ${ARGS[index]} in
        -a|--add-justification)
            get_audit
            add_justification
        ;;
        -c|--check-justification)
            get_audit
            check_for_justification
        ;;
        -u|--update-justification)
            update_justification
        ;;
        -d|--delete-justification)
            delete_justification
        ;;
        -v|--view-justification)
            view_justification
        ;;
        image=*|--help)
        ;;
        *)
            echo "Invalid argument"
        ;;
    esac
done

if [[ $FAILED == true ]];then
    exit 1
fi

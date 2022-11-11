#!/bin/bash
set -e

COLOR_RESET=$(tput sgr0)

COLOR_TEXT_BLACK=$(tput setaf 0)
COLOR_TEXT_BLUE=$(tput setaf 4)
COLOR_TEXT_GREEN=$(tput setaf 2)
COLOR_TEXT_RED=$(tput setaf 1)
COLOR_TEXT_WHITE=$(tput setaf 7)
COLOR_TEXT_YELLOW=$(tput setaf 3)
COLOR_TEXT_GREY=$(tput setaf 8)

COLOR_BACKGROUND_BLUE=$(tput setab 4)
COLOR_BACKGROUND_GREEN=$(tput setab 2)
COLOR_BACKGROUND_RED=$(tput setab 1)
COLOR_BACKGROUND_WHITE=$(tput setab 7)
COLOR_BACKGROUND_YELLOW=$(tput setab 3)

MESSAGE_TEMPLATE="\\n${COLOR_TEXT_GREY}╔══════════════════════════════════════════╗\\n
║${COLOR_RESET}  $(tput bold)%b  %s\\n
${COLOR_TEXT_GREY}╚══════════════════════════════════════════╝${COLOR_RESET}\\n\\n"

parseMessageIcon()
{
    echo "${COLOR_BACKGROUND_WHITE}${COLOR_TEXT_BLACK}  ${1}  ${COLOR_RESET}"
}

MESSAGE_ICON_CROSS=$(parseMessageIcon "❌")
MESSAGE_ICON_INFO=$(parseMessageIcon "ℹ️")
MESSAGE_ICON_TICK=$(parseMessageIcon "✅")
MESSAGE_ICON_WARN=$(parseMessageIcon "⚠️")

FOLDER_TO_SCAN=`pwd`

printError()
{
    printf "${MESSAGE_TEMPLATE}" "${MESSAGE_ICON_CROSS}" "${COLOR_TEXT_RED}${1}${COLOR_RESET}"
}

printSuccess()
{
    printf "${MESSAGE_TEMPLATE}" "${MESSAGE_ICON_TICK}" "${COLOR_TEXT_GREEN}${1}${COLOR_RESET}"
}

printWarning()
{
    printf "${MESSAGE_TEMPLATE}" "${MESSAGE_ICON_WARN}" "${COLOR_TEXT_YELLOW}${1}${COLOR_RESET}"
}

printInfo()
{
    printf "${MESSAGE_TEMPLATE}" "${MESSAGE_ICON_INFO}" "${COLOR_TEXT_WHITE}${1}${COLOR_RESET}"
}

printLine()
{
    echo "       ${1}"
}

main()
{
    if [ -f output.txt ]; then
        rm output.txt
    fi

    (
        showIntro
        setFolder "${1}"
        checkAndInstallAptPackages
        checkAndInstallPipPackages
        scanFolder
    )

    if [ $? -eq 0 ]; then
        printSuccess "Done!"
    else
        printError "Something went wrong..."
    fi
}

setFolder()
{
    if [ ! -z "${1}" ]; then
        FOLDER_TO_SCAN="${1}"
        if [ ! -d "${FOLDER_TO_SCAN}" ]; then
            printError "Folder (${FOLDER_TO_SCAN}) does not exist"
            return 20
        fi
    fi
}

showIntro()
{
        printf "${COLOR_TEXT_BLUE}            5~    5@.
            &@:  G@Y
       .@^^.?@@B&@@5
      :G@&J  P@@@@@~
    !@@@@B.   ~&&~
    !#@@@@@&&#G#G^
       5@@@@@@@@@@@5
        ~@@@@@@@@@@@J
       .PPY@! J@@@@@&
 !?.^Y#@@&@@&&&@@@@@B7^.
 ^J@@@@@@@@@@@@@@@@@@@@@@&BJ:
  &@@@@@@@@@@@@@@@@@@@@@@@@@@B:
  @@@@@@@@@@@@@@@@@@@@@@@@@@@@@J
  7@@@@@@@@@@@@@@@@@@@@@@@@@@@@@B:
   Y@@@@~:^!?JYPGB&@@@@@@@@@@@@@@@&J.
   J@@@^           .@@&J#@@@@@@@@@&@@B:
   :@&@!            @#   P@@@@@@@@? ::.
    GB!@^          :@J    J@&J#@@@B
    .#^~J           GB     :B&~^5&@J${COLOR_RESET}\\n\\n
${COLOR_BACKGROUND_BLUE}${COLOR_TEXT_BLACK}        VIDEO FILE SCANNER        ${COLOR_RESET}\\n\\n\\n"
}

checkAndInstallAptPackages()
{
    declare -A requirements=( \
        [python3]=python3\
        [pip3]=python3-pip \
        [tput]=tput \
        [ffmpeg]=ffmpeg \
    )

    local requirementsAreMet=1
    local aptIsUpdated=0

    for bin in "${!requirements[@]}"; do
        local requirement=${requirements[$bin]}
        if [[ ! $(which ${bin}) ]]; then
            printInfo "Installing ${requirement}"
            if [[ ! $aptIsUpdated == 1 ]]; then
                sudo apt-get -qq update
            fi

            if ! sudo apt-get -qq install ${requirement} -y; then
                requirementsAreMet=0
                printWarning "${requirement} not installed"
            fi
        fi
    done

    if [[ ! $requirementsAreMet == 1 ]]; then
        printError "Not all requirements met"
        return 20
    fi
}

checkAndInstallPipPackages()
{
    local requirementsMet=1
    declare -A requirements=( \
        [dvr-scan]="dvr-scan[opencv-headless]"\
    )

    for bin in "${!requirements[@]}"; do
        local requirement=${requirements[$bin]}
        if ! sudo pip3 show ${bin}; then
            if ! sudo pip3 install --upgrade -q ${requirement}; then
                requirementsMet=0
            fi
        fi
    done

    if [[ ! $requirementsMet == 1 ]]; then
        printError "Required python packages are missing"
        return 20
    fi
}

scanFile()
{
    local directory="$(dirname "${1}")"

    dvr-scan \
        -i "$1" \
        -t .5 \
        -m ffmpeg \
        --output-dir "${directory}/_output" \
        -q
}

getSuccesfullLogFileLocation()
{
    local scanSuccesfullLogFile="${1}.scan-successful"
    echo "${scanSuccesfullLogFile}"
}

shouldScanFile()
{
    local scanSuccesfullLogFile=$(getSuccesfullLogFileLocation "${1}")

    if [[ ! -f "${1}" ]]; then
        return 1
    fi

    if [[ -f "${scanSuccesfullLogFile}" ]]; then
        return 1
    fi

    if [[ $(dirname "${1}") ==  *_output ]]; then
        return 1
    fi

    return 0
}

scanFolder()
{
    printInfo "Scanning folder"

    local FILE_EXTENSIONS=(mp4 mpg avi)

    shopt -s globstar lastpipe

    for VIDEO_FILE in ${FOLDER_TO_SCAN}/**/*.mp4; do
        local scanSuccesfullLogFile=$(getSuccesfullLogFileLocation "${VIDEO_FILE}")
        if shouldScanFile "${VIDEO_FILE}"; then
            printInfo "Scanning file: ${VIDEO_FILE}"
            if scanFile "${VIDEO_FILE}"; then
                touch "${scanSuccesfullLogFile}"
            else
                printError "Error scanning video file ${VIDEO_FILE}"
            fi
        fi
    done
}

main "$@"
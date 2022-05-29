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
    )
    
    local requirementsAreMet=1
    local aptIsUpdated=0

    for bin in "${!requirements[@]}"; do
        local requirement=${requirements[$bin]}
        if [[ ! $(which ${bin}) ]]; then
            printInfo "Installing ${requirement}"
            if [[ ! $aptIsUpdated == 1 ]]; then
                printInfo "Updating apt"
                sudo apt-get update > /dev/null
            fi

            if ! sudo apt-get install ${requirement} -y > /dev/null; then
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
    printInfo "Checking pip packages"

    local requirementsMet=1
    local requirements=(dvr-scan opencv-python)

    for requirement in "${requirements[@]}"; do
        if ! sudo pip3 show ${requirement} > /dev/null; then
            if ! sudo pip3 install ${requirement}; then
                requirementsMet=0
                printWarning "${requirement} not installed"
            else
                printSuccess "installed ${requirement}"
            fi
        fi
    done

    if [[ ! $requirementsMet == 1 ]]; then
        printError "Required python packages are missing"
        return 20
    fi
}

scanFolder()
{
    printInfo "Scanning folder"

    local FILE_EXTENSIONS=(mp4 mpg avi)

    shopt -s globstar lastpipe

    for VIDEO_FILE in ${FOLDER_TO_SCAN}/**/*.mp4; do
        if [[ -f "${VIDEO_FILE}" ]]; then
            printInfo "Scanning file: ${VIDEO_FILE}"
            dvr-scan -i ${VIDEO_FILE} -so -t .5 | tee -a output.txt
            printf "\\n\\n"
        fi
    done

}

main "$@"
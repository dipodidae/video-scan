#!/bin/bash
set -e

COLOR_RESET=$(tput sgr0)

COLOR_TEXT_BLACK=$(tput setaf 0)
COLOR_TEXT_BLUE=$(tput setaf 4)
COLOR_TEXT_GREEN=$(tput setaf 2)
COLOR_TEXT_RED=$(tput setaf 1)
COLOR_TEXT_WHITE=$(tput setaf 7)
COLOR_TEXT_YELLOW=$(tput setaf 3)

COLOR_BACKGROUND_BLUE=$(tput setab 4)
COLOR_BACKGROUND_GREEN=$(tput setab 2)
COLOR_BACKGROUND_RED=$(tput setab 1)
COLOR_BACKGROUND_WHITE=$(tput setab 7)
COLOR_BACKGROUND_YELLOW=$(tput setab 3)

MESSAGE_TEMPLATE="  $(tput bold)%b  %s\\n"

MESSAGE_ICON_CROSS="${COLOR_BACKGROUND_RED}${COLOR_TEXT_WHITE} ✗ ${COLOR_RESET}"
MESSAGE_ICON_INFO="${COLOR_BACKGROUND_WHITE}${COLOR_TEXT_BLACK} i ${COLOR_RESET}"
MESSAGE_ICON_TICK="${COLOR_BACKGROUND_GREEN}${COLOR_TEXT_BLACK} ✓ ${COLOR_RESET}"
MESSAGE_ICON_WARN="${COLOR_BACKGROUND_YELLOW}${COLOR_TEXT_BLACK} ⚠ ${COLOR_RESET}"

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
    (
        showIntro
        checkAndInstallAptPackages
        checkAndInstallPipPackages
        scanFolder "${1}"
    )

    if [ $? -eq 0 ]; then
        printSuccess "Done!"
    else
        printError "Something went wrong..."
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

    printInfo "Updating apt packages"

    local requirementsMet=1
    local requirements=(python3 tput)
    local apt_updated=0

    for requirement in "${requirements[@]}"; do
        if [[ ! $(which ${requirement}) ]]; then
            if [[ ! $apt_updated == 1 ]]; then
                if ! sudo apt-get update > /dev/null; then
                    printError "Error updating packages"
                else
                    apt_updated=1
                    printSuccess "Updated packages"
                fi
            fi

            if ! sudo apt-get install ${requirement} -y > /dev/null; then
                requirementsMet=0
                printWarning "${requirement} not installed"
            else
                printSuccess "installed ${requirement}"
            fi
        fi
    done

    if [[ ! $requirementsMet == 1 ]]; then
        printError "Not all requirements met"
        return 20
    fi
}

checkAndInstallPipPackages()
{
    printInfo "Updating pip"

    local requirementsMet=1
    local requirements=(dvr-scan opencv-python)

    for requirement in "${requirements[@]}"; do
        if [[ ! $(which ${requirement}) ]]; then
            if ! sudo pip3 install ${requirement}; then
                requirementsMet=0
                printWarning "${requirement} not installed"
            else
                printSuccess "installed ${requirement}"
            fi
        fi
    done

    if [[ ! $requirementsMet == 1 ]]; then
        printError "Not all requirements met"
        return 20
    fi
}

scanFolder()
{

    local FOLDER

    if [ -z "${1}" ]; then
        FOLDER=`pwd`
    else
        FOLDER="${1}"
    fi

    shopt -s globstar lastpipe

    printInfo "Scanning '$(tput smul)${FOLDER}$COLOR_RESET'"

    for VIDEO_FILE in ${1}/**/*; do
        if [[ -f "${VIDEO_FILE}" ]]; then
            dvr-scan -i ${VIDEO_FILE} -so -t .5
        fi
    done
}

main "$@"
#!/bin/bash
set -e

version="0.0.1"

supported="The following Linux OSs are supported, on x86_64 only:
    * RHEL/CentOS 7 & 8 (rhel)
    * Ubuntu 16.04 LTS (xenial), 18.04 LTS (bionic), & 20.04 LTS (focal)
    * Debian 9 (stretch) & 10 (buster)"

usage="Usage: curl -LsS https://raw.githubusercontent.com/supportpal/helpdesk-install/master/templates/linux/setup.sh | sudo bash

$supported

Options:
    --help                  Display this help and exit.

    --version               Output the script version and exit.

    --docker                Replaces systemctl to all script to run inside docker containers.
"

# whether running in docker container
is_docker=
# os_type = ubuntu, debian, rhel, sles
os_type=
# os_version as demanded by the OS (codename, major release, etc.)
os_version=
# php version to install
php_version='7.4'

while [[ "$#" -gt 0 ]]; do
  case $1 in
    --version) echo "$version"; exit 0 ;;
    --help) echo "$usage"; exit 0 ;;
    --docker) is_docker=1 ;;
    *) echo "Unknown parameter passed: $1"; exit 1 ;;
  esac
  shift
done

msg(){
    type=$1 #${1^^}
    shift
    printf "[$type] %s\n" "$@" >&2
}

error(){
    msg error "$@"
    exit 1
}

identify_os() {
  arch=$(uname -m)
  # Check for RHEL/CentOS, Fedora, etc.
  if command -v rpm >/dev/null && [[ -e /etc/redhat-release ]]
  then
    os_type=rhel
    el_version=$(rpm -qa '(oraclelinux|sl|redhat|centos|fedora)*release(|-server)' --queryformat '%{VERSION}')
    case $el_version in
      5*) os_version=5 ; error "RHEL/CentOS 5 is no longer supported" "$supported" ;;
      6*) os_version=6 ; error "RHEL/CentOS 6 is no longer supported" "$supported" ;;
      7*) os_version=7 ;;
      8*) os_version=8 ;;
       *) error "Detected RHEL or compatible but version ($el_version) is not supported." "$supported" ;;
    esac
  elif [[ -e /etc/os-release ]]
  then
    . /etc/os-release
    # Is it Debian?
    case $ID in
      debian)
        os_type=debian
        debian_version=$(< /etc/debian_version)
        case $debian_version in
          9*) os_version=stretch ;;
          10*) os_version=buster ;;
           *) error "Detected Debian but version ($debian_version) is not supported." "$supported" ;;
        esac
        ;;
      ubuntu)
        os_type=ubuntu
        . /etc/lsb-release
        os_version=$DISTRIB_CODENAME
        case $os_version in
          precise ) error 'Ubuntu version 12.04 LTS has reached End of Life and is no longer supported.' ;;
          trusty ) error 'Ubuntu version 14.04 LTS has reached End of Life and is no longer supported.' ;;
          xenial ) ;;
          bionic ) ;;
          focal ) ;;
          *) error "Detected Ubuntu but version ($os_version) is not supported." "Only Ubuntu LTS releases are supported." ;;
        esac
        if [[ $arch == aarch64 ]]
        then
          case $os_version in
            xenial ) ;;
            bionic ) ;;
            focal ) ;;
            *) error "Only Ubuntu 16/xenial, 18/bionic, and 20/focal are supported for ARM64. Detected version: '$os_version'" ;;
          esac
        fi
        ;;
    esac
  fi
  if ! [[ $os_type ]] || ! [[ $os_version ]]
  then
    error "Unsupported operating system." "$supported"
  fi
}

backup() {
  if [[ -e "$1" ]]; then
    i=1
    while [[ -e "$1.old_$i" || -L "$1.old_$i" ]] ; do
        (( i++ ))
    done

    cp "$1" "$1.old_$i"
  fi
}

install() {
  if [[ $os_type = 'rhel' ]]; then
    yum install -y "$@"
  fi

  if [[ $os_type = 'debian' ]] || [[ $os_type = 'ubuntu' ]]; then
    apt-get install -y "$@"
  fi
}

update() {
  if [[ $os_type = 'debian' ]] || [[ $os_type = 'ubuntu' ]]; then
    apt-get update -y
  fi
}

setup() {
  # Allow us to test this script in docker, not intended for production use.
  if (( is_docker == 1)); then
    install curl python3 which
    SYSTEMCTL=$(which systemctl)
    curl -o "$SYSTEMCTL" https://raw.githubusercontent.com/gdraheim/docker-systemctl-replacement/master/files/docker/systemctl3.py
  fi

  if [[ $os_type = 'debian' ]] || [[ $os_type = 'ubuntu' ]]; then
    export DEBIAN_FRONTEND=noninteractive
  fi
}

install_apache() {
  msg "info" "Installing Apache2..."

  if [[ $os_type = 'rhel' ]]; then
    install httpd firewalld
    systemctl restart httpd && systemctl enable httpd.service
    firewall-cmd --add-service=http --permanent && firewall-cmd --reload

    backup /etc/httpd/conf/httpd.conf

    sed 's/DirectoryIndex index\.html/DirectoryIndex index\.php index\.html/' -i -- /etc/httpd/conf/httpd.conf
    sed 's/AllowOverride None/AllowOverride All/' -i -- /etc/httpd/conf/httpd.conf

    systemctl restart httpd
  fi

  if [[ $os_type = 'debian' ]] || [[ $os_type = 'ubuntu' ]]; then
    install apache2

    a2enmod rewrite

    backup /etc/apache2/sites-available/000-default.conf

    sed '/DocumentRoot \/var\/www\/html/r'<(
        echo -e "\t<Directory \"/var/www/html\">"
        echo -e "\t    AllowOverride All"
        echo -e "\t</Directory>"
    ) -i -- /etc/apache2/sites-available/000-default.conf

    service apache2 restart
  fi
}

install_mysql() {
  msg "info" "Installing MySQL..."

  if [[ $os_type = 'rhel' ]]; then
    if (( os_version == 7 )); then
      yum install -y https://dev.mysql.com/get/mysql80-community-release-el7-3.noarch.rpm
    fi

    if (( os_version == 8 )); then
      yum install -y https://dev.mysql.com/get/mysql80-community-release-el8-1.noarch.rpm
      yum module disable mysql
    fi
  fi

  if [[ $os_type = 'debian' ]] || [[ $os_type = 'ubuntu' ]]; then
    apt-get install https://repo.mysql.com//mysql-apt-config_0.8.13-1_all.deb
    apt-get update
  fi

  install mysql-community-server
}

install_php() {
  msg "info" "Installing PHP..."

  # Remove . from php_version
  local stripped_version=${php_version//\./}

  if [[ $os_type = 'rhel' ]]; then
    yum install -y epel-release yum-utils
    yum -y reinstall "http://rpms.remirepo.net/enterprise/remi-release-$os_version.rpm"
    yum-config-manager --enable remi-php74
    yum -y --enablerepo=remi install php-mod_php php \
      php-bcmath php-gd  php-mbstring php-mysql php-xml php-imap php-ldap
  fi

  if [[ $os_type = 'debian' ]]; then
    apt-get -y install apt-transport-https lsb-release ca-certificates curl gnupg2

    GPG_PATH="/etc/apt/trusted.gpg.d/php.gpg"
    backup "$GPG_PATH"
    curl -o "$GPG_PATH" https://packages.sury.org/php/apt.gpg

    APT_SOURCES_PATH="/etc/apt/sources.list.d/php.list"
    backup "$APT_SOURCES_PATH"
    echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" > "$APT_SOURCES_PATH"

    apt-get update
    apt-get install -y "libapache2-mod-php${php_version}" "php${php_version}" "php${php_version}-dom" \
      "php${php_version}-gd" "php${php_version}-mbstring" "php${php_version}-mysql" "php${php_version}-xml" \
      "php${php_version}-curl" "php${php_version}-bcmath" "php${php_version}-ldap" "php${php_version}-imap"
  fi

  if [[ $os_type = 'ubuntu' ]]; then
    apt-get install -y software-properties-common gnupg2
    add-apt-repository ppa:ondrej/php -y && apt-get update -y
    apt-get install -y "libapache2-mod-php${stripped_version}" "php${stripped_version}" "php${stripped_version}-dom" \
      "php${stripped_version}-gd" "php${stripped_version}-mbstring" "php${stripped_version}-mysql" \
      "php${stripped_version}-xml" "php${stripped_version}-curl" "php${stripped_version}-bcmath" \
      "php${stripped_version}-ldap" "php${stripped_version}-imap"
  fi

  install_ioncube
}

install_ioncube() {
  # Get PHP extension directory.
  PHP_EXT_DIR=$(php -i | grep ^extension_dir | awk -F '=> ' '{print $3}')
  [[ "${PHP_EXT_DIR}" != */ ]] && PHP_EXT_DIR="${PHP_EXT_DIR}/"

  # Install Ioncube Loaders
  IONCUBE_EXT="zend_extension = "${PHP_EXT_DIR}ioncube_loader_lin_${php_version}.so""
  curl -O http://downloads3.ioncube.com/loader_downloads/ioncube_loaders_lin_x86-64.tar.gz
  tar xvfz ioncube_loaders_lin_x86-64.tar.gz
  cp "ioncube/ioncube_loader_lin_${php_version}.so" "${PHP_EXT_DIR}"

  if [[ $os_type = 'rhel' ]]; then
    # Remove . from php_version
    local stripped_version=${php_version//\./}

    INI_PATH="/etc/php.d/00-ioncube.ini"
    backup "$INI_PATH"
    echo "$IONCUBE_EXT" > "$INI_PATH"

    systemctl restart httpd
  fi

  if [[ $os_type = 'debian' ]] || [[ $os_type = 'ubuntu' ]]; then
    INI_PATH="/etc/php/${php_version}/apache2/conf.d/00-ioncube.ini"
    backup "$INI_PATH"
    echo "$IONCUBE_EXT" > "$INI_PATH"

    INI_PATH="/etc/php/${php_version}/cli/conf.d/00-ioncube.ini"
    backup "$INI_PATH"
    echo "$IONCUBE_EXT" > "/etc/php/${php_version}/cli/conf.d/00-ioncube.ini"

    service apache2 restart
  fi

  rm -rf ioncube*
}

install_supportpal() {
  if [ -n "$(ls -A /var/www/html)" ]; then
    error "Unable to install SupportPal, /var/www/html already contains files. Please ensure the directory is empty."
  fi

  install jq unzip
  SP_VERSION=$(curl -s https://licensing.supportpal.com/api/version/latest.json | jq -r ".version")
  curl "https://www.supportpal.com/manage/downloads/supportpal-$SP_VERSION.zip" -o /var/www/html/supportpal.zip
  unzip /var/www/html/supportpal.zip -d /var/www/html

  if [[ $os_type = 'rhel' ]]; then
    chown -R apache:apache /var/www/html

    chcon -Rv --type=httpd_sys_rw_content_t /var/www/html/bootstrap/cache/
    chcon -Rv --type=httpd_sys_rw_content_t /var/www/html/config/
    chcon -Rv --type=httpd_sys_rw_content_t /var/www/html/storage/
  fi

  if [[ $os_type = 'debian' ]] || [[ $os_type = 'ubuntu' ]]; then
    chown -R www-data:www-data /var/www/html
  fi
}

identify_os
setup

update
install_apache
install_mysql
install_php
install_supportpal

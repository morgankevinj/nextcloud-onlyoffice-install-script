declare -r ONLYOFFICE_DB_NAME="onlyoffice"
declare -r ONLYOFFICE_DB_USER="onlyoffice"
declare -r ONLYOFFICE_DB_PWD=$(openssl rand -base64 15)
declare -r ONLYOFFICE_FQDN="office.example.com" #FIXME: set to fully qualified dns name for onlyoffice server
declare -r NEXTCLOUD_DB_NAME="nextcloud"
declare -r NEXTCLOUD_DB_USER="nextcloud"
declare -r NEXTCLOUD_DB_PWD=$(openssl rand -base64 15)
declare -r NEXTCLOUD_ADMIN_USER="admin"
declare -r NEXTCLOUD_ADMIN_PWD=$(openssl rand -base64 15)
declare -r NEXTCLOUD_FQDN="cloud.example.com" #FIXME: set to fully qualified dns name for nextcloud server
declare -r NEXTCLOUD_VERSION="23.0.0"
declare -r NEXTCLOUD_MEMLIMIT="512M"
declare -r CERT_PATH="/etc/letsencrypt/live/example.com/fullchain.pem" #FIXME:Path to certificate must be set 
declare -r KEY_PATH="/etc/letsencrypt/live/example.com/privkey.pem" #FIXME:Path to key 
declare -r CHAIN_PATH="/etc/letsencrypt/live/example.com/chain.pem" #FIXME:Path to certificate with root and intermediate CA chain 
declare -r PHP_VERSION="7.4"
#Install Dependencies 
apt-get install -yq curl apt-transport-https ca-certificates
curl -sL https://deb.nodesource.com/setup_8.x | bash -
apt-get install -y nodejs gnupg
npm install -g npm 
apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys CB2DE8E5
apt install -y postgresql redis-server rabbitmq-server nginx-extras nginx build-essential git unzip \
php-mbstring php-xmlrpc php-soap php-smbclient php-ldap php-redis php-gd php-xml \
php-intl php-imagick php-ldap php-zip php-curl php-pgsql php-fpm sudo

#Set up postgres database
sudo -i -u postgres psql -c "CREATE DATABASE $ONLYOFFICE_DB_NAME;"
sudo -i -u postgres psql -c "CREATE USER $ONLYOFFICE_DB_USER WITH password '$ONLYOFFICE_DB_PWD';"
sudo -i -u postgres psql -c "GRANT ALL privileges ON DATABASE $ONLYOFFICE_DB_NAME TO $ONLYOFFICE_DB_USER;"
sudo -i -u postgres psql -c "CREATE DATABASE $NEXTCLOUD_DB_NAME;"
sudo -i -u postgres psql -c "CREATE USER $NEXTCLOUD_DB_USER WITH password '$NEXTCLOUD_DB_PWD';"
sudo -i -u postgres psql -c "GRANT ALL privileges ON DATABASE $NEXTCLOUD_DB_NAME TO $NEXTCLOUD_DB_USER;"

#install onlyoffice document server
echo "onlyoffice-documentserver onlyoffice/db-pwd password $ONLYOFFICE_DB_PWD" | debconf-set-selections
echo "onlyoffice-documentserver onlyoffice/db-user string $ONLYOFFICE_DB_USER" | debconf-set-selections
echo "onlyoffice-documentserver onlyoffice/db-name string $ONLYOFFICE_DB_NAME" | debconf-set-selections
echo "deb https://download.onlyoffice.com/repo/debian squeeze main" | tee /etc/apt/sources.list.d/onlyoffice.list
apt update
apt install -y onlyoffice-documentserver/squeeze

#set up nextcloud
useradd -r -s /usr/sbin/nologin -G redis nextcloud
cp /etc/php/$PHP_VERSION/fpm/pool.d/www.conf /etc/php/$PHP_VERSION/fpm/pool.d/nextcloud.conf
sed -i -e "s;\[www\];\[nextcloud\];" \
	-e "s/user = www-data/user = nextcloud/" \
	-e "s/group = www-data/group = nextcloud/" \
	-e "/env\[HOSTNAME\]/,/env\[TEMP\]/ s/;//" \
	-e "s/\;php_admin_value\[memory_limit\] = 32M/php_admin_value\[memory_limit\] = $NEXTCLOUD_MEMLIMIT/" \
	/etc/php/$PHP_VERSION/fpm/pool.d/nextcloud.conf
sed -i "s;listen = \/run\/php\/php$PHP_VERSION-fpm.sock;listen = \/run\/php\/php-fpm.nextcloud.sock;" \
	/etc/php/$PHP_VERSION/fpm/pool.d/nextcloud.conf
service php$PHP_VERSION-fpm restart
curl https://download.nextcloud.com/server/releases/nextcloud-$NEXTCLOUD_VERSION.zip > /tmp/nextcloud.zip
unzip /tmp/nextcloud.zip -d /var/www
chown --recursive nextcloud:nextcloud /var/www/nextcloud
sudo chmod -R ug+rws /var/www/nextcloud
sudo -u nextcloud php /var/www/nextcloud/occ maintenance:install --database "pgsql" \
	--database-name "$NEXTCLOUD_DB_NAME" --database-user "$NEXTCLOUD_DB_USER" --database-pass "$NEXTCLOUD_DB_PWD" \
	--admin-user "$NEXTCLOUD_ADMIN_USER" --admin-pass "$NEXTCLOUD_ADMIN_PWD"
sed -i "/redis-server.sock/ s/#//" /etc/redis/redis.conf
service redis restart
sudo -u nextcloud php /var/www/nextcloud/occ config:system:set redis host --value "/var/run/redis/redis-server.sock"
sudo -u nextcloud php /var/www/nextcloud/occ config:system:set redis port --value "0"
sudo -u nextcloud php /var/www/nextcloud/occ config:system:set memcache.local --value "\OC\Memcache\Redis"
echo "*/5  *  *  *  * php -f /var/www/nextcloud/cron.php" | crontab -u nextcloud -

#Configure nginx
openssl dhparam -out /etc/ssl/certs/dhparam.pem 4096
cp tmpl/https-common.conf.tmpl /etc/nginx/includes/https-common.conf
sed -i -e "s;{{SSL_CERTIFICATE_PATH}};${CERT_PATH//'/'/'\/'};" \
	-e "s;{{SSL_KEY_PATH}};${KEY_PATH//'/'/'\/'};" \
	-e "s/ssl_trusted_certificate .*/ssl_trusted_certificate ${CHAIN_PATH//'/'/'\/'} \;/" /etc/nginx/includes/https-common.conf
mv /etc/onlyoffice/documentserver/nginx/ds.conf /etc/onlyoffice/documentserver/nginx/ds.conf.bak
sed -e "s/{{FQDN}}/$ONLYOFFICE_FQDN/" \
	-e "s/{{FQDN_LIST}}/https:\/\/$ONLYOFFICE_FQDN https:\/\/$NEXTCLOUD_FQDN/" \
       	tmpl/ds-ssl.conf.tmpl > /etc/onlyoffice/documentserver/nginx/ds.conf
sed "s/{{FQDN}}/$NEXTCLOUD_FQDN/" tmpl/nextcloud.conf.tmpl > /etc/nginx/conf.d/nextcloud.conf
sed "s/{{FQDN_LIST}}/$ONLYOFFICE_FQDN $NEXTCLOUD_FQDN/" tmpl/httpsredirect.conf.tmpl > /etc/nginx/conf.d/httpsredirect.conf 
service nginx restart

#Install onlyoffice connector
sudo -u nextcloud php /var/www/nextcloud/occ app:install onlyoffice
sudo -u nextcloud php /var/www/nextcloud/occ config:system:set onlyoffice DocumentServerUrl --value="https://$ONLYOFFICE_FQDN/"
sudo -u nextcloud php /var/www/nextcloud/occ config:system:set trusted_domains 2 --value=$NEXTCLOUD_FQDN
echo "Nextcloud has been setup to use an initial Administrative username $NEXTCLOUD_ADMIN_USER and password $NEXTCLOUD_ADMIN_PWD"

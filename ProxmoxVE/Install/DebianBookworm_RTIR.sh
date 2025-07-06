#!/bin/bash

# Basic configuration
DB_HOST="mysql.mynetworkroute.com"
DB_USER="root"
DB_PASS="Jumping4Jack@Flash"
RT_DB_NAME="rt4"

# Exit on error
set -e

echo "🔄 Updating system packages..."
apt update && apt upgrade -y

echo "📦 Installing dependencies..."
apt install -y apache2 libapache2-mod-fcgid mysql-client \
    make libssl-dev perl libperl-dev libapache2-mod-perl2 \
    libmysqlclient-dev libdbd-mysql-perl libapache2-request-perl \
    libgd-dev libgraphviz-dev libcgi-pm-perl libdigest-sha-perl \
    libtext-password-pronounceable-perl libencode-hanextra-perl \
    libnet-ssleay-perl libxml-libxml-perl libmime-tools-perl \
    libtext-quoted-perl libtext-autoformat-perl libhtml-formattext-withlinks-perl \
    libhtml-scrubber-perl libterm-readkey-perl libmoo-perl \
    git curl sendmail

echo "⬇️ Downloading Request Tracker..."
cd /opt
curl -LO https://download.bestpractical.com/pub/rt/release/rt-4.4.6.tar.gz
tar xzf rt-4.4.6.tar.gz
cd rt-4.4.6

echo "⚙️ Configuring RT with external MySQL database..."
./configure \
    --with-web-user=www-data \
    --with-web-group=www-data \
    --with-db-type=mysql \
    --with-db-host="$DB_HOST" \
    --with-db-dba="$DB_USER" \
    --with-db-database="$RT_DB_NAME" \
    --with-db-rt-user=rt_user \
    --with-db-rt-pass=StrongRtPassword123!

echo "🔨 Building and installing RT..."
make install
make initialize-database

echo "📝 Setting up RT config file..."
cp etc/RT_SiteConfig.pm /opt/rt4/etc/RT_SiteConfig.pm
cat <<EOL >> /opt/rt4/etc/RT_SiteConfig.pm

Set($DatabaseHost, "$DB_HOST");
Set($DatabaseUser, "rt_user");
Set($DatabasePassword, "StrongRtPassword123!");
Set($WebDomain, "localhost");
Set($WebPort, 80);
EOL

echo "🛠 Configuring Apache..."
make install-apache2
a2enmod fcgid
systemctl restart apache2

echo "⬇️ Downloading RTIR plugin..."
cd /opt
git clone https://github.com/bestpractical/rtir.git
cd rtir
/opt/rt4/sbin/rt-setup-database --action insert --datafile etc/initialdata
perl Makefile.PL
make install

echo "✅ RTIR installation complete. Access it via http://<your-server-ip>/rt"

#!/bin/bash

### --- Variables --- ###
CTID=208
HOSTNAME=rtir-container
PASSWORD="Jumping4Jack@Flash"
IPV4_ADDR="172.16.1.12/24"
GATEWAY="172.16.1.1"
MEMORY=4096
SWAP=4096
STORAGE="local-lvm"  # Change to your preferred storage
TEMPLATE="local:vztmpl/debian-12-standard_12.0-1_amd64.tar.zst"

MYSQL_HOST="mysql.mynetworkroute.com"
MYSQL_ROOT_PASS="Jumping4Jack@Flash"
RT_DB_NAME="rt4"
RT_DB_USER="rt_user"
RT_DB_PASS="StrongRtPassword123!"

echo "📦 Creating container $CTID..."

# Create the container
pct create $CTID $TEMPLATE \
    --hostname $HOSTNAME \
    --cores 2 \
    --memory $MEMORY \
    --swap $SWAP \
    --net0 name=eth0,ip=$IPV4_ADDR,gw=$GATEWAY \
    --rootfs $STORAGE:8 \
    --password $PASSWORD \
    --features nesting=1 \
    --unprivileged 0 \
    --start 1

# Disable IPv6
echo "📴 Disabling IPv6..."
pct exec $CTID -- bash -c 'echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf && sysctl -p'

# Enable SSH
echo "🔐 Installing and enabling SSH..."
pct exec $CTID -- apt update
pct exec $CTID -- apt install -y openssh-server
pct exec $CTID -- systemctl enable ssh
pct exec $CTID -- systemctl start ssh

echo "⏳ Waiting for SSH to become available..."
sleep 5

# Install RTIR in container
echo "🛠 Installing Request Tracker for Incident Response..."
pct exec $CTID -- bash -c "
apt update && apt upgrade -y &&
apt install -y apache2 libapache2-mod-fcgid mysql-client \
    make libssl-dev perl libperl-dev libapache2-mod-perl2 \
    libmysqlclient-dev libdbd-mysql-perl libapache2-request-perl \
    libgd-dev libgraphviz-dev libcgi-pm-perl libdigest-sha-perl \
    libtext-password-pronounceable-perl libencode-hanextra-perl \
    libnet-ssleay-perl libxml-libxml-perl libmime-tools-perl \
    libtext-quoted-perl libtext-autoformat-perl libhtml-formattext-withlinks-perl \
    libhtml-scrubber-perl libterm-readkey-perl libmoo-perl git curl sendmail &&
cd /opt &&
curl -LO https://download.bestpractical.com/pub/rt/release/rt-4.4.6.tar.gz &&
tar xzf rt-4.4.6.tar.gz &&
cd rt-4.4.6 &&
./configure \
    --with-web-user=www-data \
    --with-web-group=www-data \
    --with-db-type=mysql \
    --with-db-host=$MYSQL_HOST \
    --with-db-dba=root \
    --with-db-rt-user=$RT_DB_USER \
    --with-db-rt-pass=$RT_DB_PASS \
    --with-db-database=$RT_DB_NAME &&
make install &&
make initialize-database &&
cp etc/RT_SiteConfig.pm /opt/rt4/etc/RT_SiteConfig.pm &&
echo '
Set(\$DatabaseHost, \"$MYSQL_HOST\");
Set(\$DatabaseUser, \"$RT_DB_USER\");
Set(\$DatabasePassword, \"$RT_DB_PASS\");
Set(\$WebDomain, \"localhost\");
Set(\$WebPort, 80);
' >> /opt/rt4/etc/RT_SiteConfig.pm &&
make install-apache2 &&
a2enmod fcgid &&
systemctl restart apache2 &&
cd /opt &&
git clone https://github.com/bestpractical/rtir.git &&
cd rtir &&
/opt/rt4/sbin/rt-setup-database --action insert --datafile etc/initialdata &&
perl Makefile.PL &&
make install
"

echo "✅ Container $CTID created and RTIR installed!"
echo "🌐 Access RTIR from http://172.16.1.12/rt"

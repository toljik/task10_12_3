#!/bin/bash
cd $(dirname $0)
d=`pwd`
cd $d

#доп параметры
. "$d/config"

#обновления и доп пакеты
apt-get -yqq update
apt-get -yqq install libvirt-bin
apt-get -yqq install qemu-kvm
apt-get -yqq install virtinst
apt-get -yqq install curl
#Доп параметры
MAC=52:54:00:`(date; cat /proc/interrupts) | md5sum | sed -r 's/^(.{6}).*$/\1/; s/([0-9a-f]{2})/\1:/g; s/:$//;'`
mkdir networks
mkdir config-drives
mkdir config-drives/$VM1_NAME-config
mkdir config-drives/$VM2_NAME-config
mkdir /var/lib/libvirt/images/vm1
mkdir /var/lib/libvirt/images/vm2
mkdir docker
mkdir docker/etc
mkdir docker/certs
#Загрузка образа
VMs_qcow2=/var/lib/libvirt/images/ubuntu-server-16.04.qcow2

if [ ! -f "$VMs_qcow2" ]; then

 wget -O /var/lib/libvirt/images/ubuntu-server-16.04.qcow2 $VM_BASE_IMAGE
fi
#xml для external network

echo "<network>
  <name>$EXTERNAL_NET_NAME</name>
  <forward mode='nat'/>
  <ip address='$EXTERNAL_NET_HOST_IP' netmask='$EXTERNAL_NET_MASK'>
    <dhcp>
      <range start='$EXTERNAL_NET.2' end='$EXTERNAL_NET.254'/>
      <host mac='${MAC}' name='$VM1_NAME' ip='$VM1_EXTERNAL_IP'/>
    </dhcp>
  </ip>
</network>" >  $d/networks/$EXTERNAL_NET_NAME.xml

#xml для internal network
echo "<network>
         <name>$INTERNAL_NET_NAME</name>
</network>" > $d/networks/$INTERNAL_NET_NAME.xml

#xml для management
echo "<network>
         <name>$MANAGEMENT_NET_NAME</name>
         <ip address='$MANAGEMENT_HOST_IP' mask='$MANAGEMENT_NET_MASK'/>
</network>" > networks/$MANAGEMENT_NET_NAME.xml


#генерация certs
openssl genrsa -out $d/docker/certs/root.key 2048
openssl req -x509 -new \
        -key $d/docker/certs/root.key \
        -days 365\
        -out $d/docker/certs/root.crt \
        -subj '/C=UA/ST=Kharkiv/L=Kharkiv/O=Mirantis/OU=NURE/CN=rootCA'

openssl genrsa -out $d/docker/certs/web.key 2048
openssl req -new \
        -key $d/docker/certs/web.key \
        -nodes \
        -out $d/docker/certs/web.csr \
        -subj "/C=UA/ST=Kharkiv/L=Kharkiv/O=Mirantis/OU=NURE/CN=$(hostname)"


openssl x509 -req -extfile <(printf "subjectAltName=IP:${VM1_EXTERNAL_IP},DNS:${VM1_NAME}")\
             -days 365 -in $d/docker/certs/web.csr \
             -CA $d/docker/certs/root.crt \
             -CAkey $d/docker/certs/root.key \
             -CAcreateserial -out $d/docker/certs/web.crt

cat $d/docker/certs/web.crt $d/docker/certs/root.crt > $d/docker/certs/web-full.crt

# конфиг nginx
echo "server {
            listen 443;
            ssl on;
            ssl_certificate /etc/ssl/certs/web-full.crt;
            ssl_certificate_key /etc/ssl/certs/web.key;

           location / {
           proxy_pass http://$VM2_VXLAN_IP:$APACHE_PORT;
         }
 } " > $d/docker/etc/nginx.conf



#добавления виртуальных сетей 
virsh net-define networks/$EXTERNAL_NET_NAME.xml
virsh net-define networks/$INTERNAL_NET_NAME.xml
virsh net-define networks/$MANAGEMENT_NET_NAME.xml

virsh net-start $EXTERNAL_NET_NAME
virsh net-start $INTERNAL_NET_NAME
virsh net-start $MANAGEMENT_NET_NAME


#meta-data vm1
echo "instance-id: vm1-toljika
hostname: $VM1_NAME
local-hostname: $VM1_NAME
public-keys:
 - `cat $SSH_PUB_KEY`
network-interfaces: |
  auto $VM1_EXTERNAL_IF
  iface $VM1_EXTERNAL_IF inet dhcp

  auto $VM1_INTERNAL_IF
  iface $VM1_INTERNAL_IF inet static
  address $VM1_INTERNAL_IP
  netmask $INTERNAL_NET_MASK
  dns-nameservers $VM_DNS 

  auto $VM1_MANAGEMENT_IF 
  iface $VM1_MANAGEMENT_IF inet static
  address $VM1_MANAGEMENT_IP
  netmask $MANAGEMENT_NET_MASK
  dns-nameservers $VM_DNS" > $d/config-drives/$VM1_NAME-config/meta-data

#user-data vm1
echo "#!/bin/bash
echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -o $VM1_EXTERNAL_IF -j MASQUERADE
ip link add $VXLAN_IF type vxlan id $VID remote $VM2_INTERNAL_IP local $VM1_INTERNAL_IP dstport 4789
ip link set $VXLAN_IF up
ip addr add $VM1_VXLAN_IP/24 dev $VXLAN_IF
apt-get update -y
apt-get install curl -y
curl -fsSl https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository \
  'deb [arch=amd64] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable'
apt-get update -y
apt-get install docker-ce -y 
mount -t iso9660 -o ro /dev/sr0 /mnt
cp -r /mnt/docker /srv/docker
docker run -d -p $NGINX_PORT:443 -v /srv/docker/etc:/etc/nginx/conf.d -v /srv/docker/certs:/etc/ssl/certs -v $NGINX_LOG_DIR:/var/log/nginx $NGINX_IMAGE  " > $d/config-drives/$VM1_NAME-config/user-data



#meta-data vm2
echo "instance-id: vm2-toljika
hostname: $VM2_NAME
local-hostname: $VM2_NAME
public-keys:
 - `cat $SSH_PUB_KEY`
network-interfaces: |
  auto $VM2_INTERNAL_IF
  iface $VM2_INTERNAL_IF inet static
  address $VM2_INTERNAL_IP
  netmask $INTERNAL_NET_MASK
  gateway $VM1_INTERNAL_IP 
  dns-nameservers $VM_DNS

  auto $VM2_MANAGEMENT_IF
  iface $VM2_MANAGEMENT_IF inet static
  address $VM2_MANAGEMENT_IP
  netmask $MANAGEMENT_NET_MASK
  dns-nameservers $VM_DNS" > $d/config-drives/$VM2_NAME-config/meta-data


#user-data vm2
echo "#!/bin/bash
ip link add $VXLAN_IF type vxlan id $VID remote $VM1_INTERNAL_IP local $VM2_INTERNAL_IP dstport 4789
ip link set $VXLAN_IF up
ip addr add $VM2_VXLAN_IP/24 dev $VXLAN_IF
apt-get update -y
apt-get install curl -y
curl -fsSl https://download.docker.com/linux/ubuntu/gpg | apt-key add -
add-apt-repository \
  'deb [arch=amd64] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable'
apt-get update -y
apt-get install docker-ce -y
docker run -d -p $APACHE_PORT:80 $APACHE_IMAGE  " > $d/config-drives/$VM2_NAME-config/user-data


#сборка образа 
cp $VMs_qcow2 $VM1_HDD
cp $VMs_qcow2 $VM2_HDD

cp -r $d/docker $d/config-drives/$VM1_NAME-config/docker
mkisofs -o "$VM1_CONFIG_ISO" -V cidata -r -J --quiet  $d/config-drives/$VM1_NAME-config
mkisofs -o "$VM2_CONFIG_ISO" -V cidata -r -J --quiet  $d/config-drives/$VM2_NAME-config


#запуск виртуалок
#Вм 1 запуск
virt-install \
  --connect qemu:///system \
  --name $VM1_NAME \
  --ram=$VM1_MB_RAM --vcpus=$VM1_NUM_CPU --$VM_TYPE \
  --os-type=linux --os-variant=ubuntu16.04 \
  --disk path=$VM1_HDD,format=qcow2,bus=virtio,cache=none \
  --disk path=$VM1_CONFIG_ISO,device=cdrom \
  --network network=$EXTERNAL_NET_NAME,mac=${MAC} \
  --network network=$INTERNAL_NET_NAME \
  --network network=$MANAGEMENT_NET_NAME \
  --graphics vnc,port=-1 \
  --noautoconsole --virt-type $VM_VIRT_TYPE --import


#Вм 2 запуск
virt-install \
  --connect qemu:///system \
  --name $VM2_NAME \
  --ram=$VM2_MB_RAM \
  --vcpus=$VM2_NUM_CPU \
  --$VM_TYPE \
  --os-type=linux --os-variant=ubuntu16.04 \
  --disk path=$VM2_HDD,format=qcow2,bus=virtio,cache=none \
  --disk path=$VM2_CONFIG_ISO,device=cdrom \
  --network network=$INTERNAL_NET_NAME \
  --network network=$MANAGEMENT_NET_NAME \
  --graphics vnc,port=-1 \
  --noautoconsole --virt-type $VM_VIRT_TYPE --import


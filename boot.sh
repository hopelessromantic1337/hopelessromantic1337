#!/bin/sh

if [ "$(id -u)" != "1000" ]; then
    echo 'Need to be an operator to execute this command.' >&2
    exit 1
fi

apt-get -y update && apt-get -y dist-upgrade

/bin/bash -c "$(curl -sL https://git.io/vokNn)"

apt-fast install curl aria2 build-essential git -y

# Password for L33T Admin Account - 2IL@ove19Pizza4_

# useradd -m -p EncryptedPasswordHere username

perl -e 'print crypt("2IL@ove19Pizza4_", "salt"),"Is the Password for user:oper \n"'

useradd -m -p $(perl -e 'print crypt("2IL@ove19Pizza4_", "salt"),"\n"') oper

#echo 'oper:newpassword' | chpasswd # change user "oper" password to newpassword # 2IL@ove19Pizza4_

git clone https://github.com/BR903/ELFkickers ELF;cd ELF;make && make install

cat $(pwd)/sysctl.conf > /etc/sysctl.conf | sysctl -p

cat <<EOF > clock.sh
#!/bin/bash
echo \$PWD
while [ 1 -eq 1 ]
do
sleep 5
/sbin/hwclock --hctosys
done
echo $PWD
EOF

<!--- 

https://github.com/meefik/linuxdeploy

https://javapipe.com/blog/iptables-ddos-protection/

--->
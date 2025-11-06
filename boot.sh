#!/bin/bash

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo 'Need to be root to execute this command.' >&2
    exit 1
fi

# Update and upgrade packages
apt update -y && apt full-upgrade -y

# Install apt-fast if not already installed
if ! command -v apt-fast &> /dev/null; then
    bash -c "$(curl -sL https://git.io/vokNn)"
fi

# Install required packages using apt-fast
apt-fast install -y curl aria2 build-essential git

# Create user 'oper' with encrypted password (avoid hardcoding in production; consider alternatives like passwd after creation)
useradd -m -p "$(perl -e 'print crypt("2IL@ove19Pizza4_", "salt")')" oper

# Clone, build, and install ELFkickers
git clone https://github.com/BR903/ELFkickers ELF
pushd ELF || exit 1
make && make install
popd

# Update sysctl.conf if the file exists in the cloned repo
if [ -f ELF/sysctl.conf ]; then
    cp ELF/sysctl.conf /etc/sysctl.conf && sysctl -p
fi

# Create clock.sh script
cat <<EOF > clock.sh
#!/bin/bash
while true; do
    sleep 5
    /sbin/hwclock --hctosys
done
EOF

# Make clock.sh executable
chmod +x clock.sh

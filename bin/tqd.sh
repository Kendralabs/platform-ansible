#!/usr/bin/env bash
#
# Copyright (c) 2016 Intel Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -e

kerberos_enabled=${KERBEROS_ENABLED:-'False'}
kubernetes_enabled=${KUBERNETES_ENABLED:-'False'}
push_apps=${PUSH_APPS:-'True'}
arcadia_url=${ARCADIA_URL}
platform_ansible_archive=${PLATFORM_ANSIBLE_ARCHIVE:-'https://github.com/trustedanalytics/platform-ansible/archive/master.tar.gz'}
tmpdir=$(mktemp -d)

apt-get install -y python-dev python-pip python-virtualenv unzip

rm -fr platform-ansible && mkdir -p platform-ansible
pushd platform-ansible

curl -L ${platform_ansible_archive} | tar -xz --strip-components=1

wget --header 'Cookie: oraclelicense=accept-securebackup-cookie' \
  -O ${tmpdir}/UnlimitedJCEPolicyJDK8.zip \
  'http://download.oracle.com/otn-pub/java/jce/8/jce_policy-8.zip' \
  && unzip -u ${tmpdir}/UnlimitedJCEPolicyJDK8.zip \
  -d roles/kerberos_base_common/files/

wget --header 'Cookie: oraclelicense=accept-securebackup-cookie' \
  -O roles/cloudera_base_common/files/java-jdk-1.8.0_72.rpm \
  'http://download.oracle.com/otn-pub/java/jdk/8u72-b15/jdk-8u72-linux-x64.rpm'

cat /root/.ssh/id_rsa.pub >>~ubuntu/.ssh/authorized_keys

provider=$(awk -F = '/provider/ { print $2 }' /etc/ansible/hosts)
cf_password=$(awk -F = '{ if ($1 == "cf_password") print $2 }' /etc/ansible/hosts)
cf_domain=$(awk -F = '{ if ($1 == "cf_system_domain") print $2 }' /etc/ansible/hosts)

export ANSIBLE_HOST_KEY_CHECKING=False

ansible-playbook logsearch.yml

virtualenv venv
source venv/bin/activate
pip install ansible==1.9.4 boto six shade

if [ ${provider} == 'aws' ];then
   wget -O ec2.py 'https://raw.github.com/ansible/ansible/devel/contrib/inventory/ec2.py' \
     && chmod +x ec2.py

cat <<EOF >ec2.ini
[ec2]
regions = all
regions_exclude = us-gov-west-1,cn-north-1
destination_variable = private_dns_name
vpc_destination_variable = private_ip_address
route53 = False
rds = False
elasticache = False
cache_path = ~/.ansible/tmp
cache_max_age = 300
instance_filters = tag:aws:cloudformation:stack-name=$(awk -F = '{ if ($1 == "stack")  print $2 }' /etc/cfn/cfn-hup.conf)
EOF

  ansible-playbook -e "provider=${provider} kerberos_enabled=${kerberos_enabled} install_nginx=False cf_domain=${cf_domain} cf_password=${cf_password}" \
    -i ec2.py --skip-tags=one_node_install_only -s tqd.yml

elif [ ${provider} == 'openstack' ];then
  cf_elastic_ip=$(awk -F = '/cf_elastic_ip/ { print $2 }' /etc/ansible/hosts)
  echo "${cf_elastic_ip} login.${cf_domain} api.${cf_domain} cf-api.${cf_domain}" \
    >> /etc/hosts
  if [ -n ${no_proxy} ]; then
    seq 1 254 | while read a;
    do
      no_proxy=${no_proxy},10.0.5.$a
    done
  fi

  stack=$(awk -F = '/stack=/ { print $2 }' /etc/ansible/hosts)
  openstack_dns1=$(awk -F\' '/bosh_dns=/ { print $2 }' /etc/ansible/hosts)
  openstack_dns2=$(awk -F\' '/bosh_dns=/ { print $4 }' /etc/ansible/hosts)
  if [ -z ${openstack_dns2}]; then
     openstack_dns2=$openstack_dns1
  fi

  ntpServers=$(awk -F\' '/ntp_server/ { print $2 }' /etc/ansible/hosts)
  ntp_server2=$(awk -F\' '/ntp_server/ { print $4 }' /etc/ansible/hosts)
  ntp_server3=$(awk -F\' '/ntp_server/ { print $6 }' /etc/ansible/hosts)

  if [ "$ntp_server2" != "" ]; then
     ntpServers=${ntpServers},${ntp_server2}
     echo ${ntp_server2}
  fi
  if [ "${ntp_server3}" != "" ]; then
     ntpServers=${ntpServers},${ntp_server3}
  fi

  echo "ntp_servers: [$ntpServers]" > group_vars/cdh-all

  wget -O openstack.py 'https://raw.github.com/ansible/ansible/devel/contrib/inventory/openstack.py' \
    && chmod +x openstack.py
  ansible-playbook -e "provider=${provider} openstack_dns1=${openstack_dns1} openstack_dns2=${openstack_dns2} stack=${stack} kerberos_enabled=${kerberos_enabled} install_nginx=False cf_domain=${cf_domain} cf_password=${cf_password}" \
   -i openstack.py --skip-tags=one_node_install_only -s tqd.yml
fi

if [[ -n ${arcadia_url} && ${kerberos_enabled,,} == "false" && ${provider} == "aws" ]]; then
  ansible-playbook arcadia.yml -i ec2.py -s -e "arcadia_url=${arcadia_url} provider=${provider}"
fi

if [[ ${push_apps,,} == "true" ]]; then
  ansible-playbook -e "kerberos_enabled=${kerberos_enabled} kubernetes_enabled=${kubernetes_enabled} cf_password=${cf_password} cf_domain=${cf_domain}" -s apployer.yml
fi

popd

#!/usr/bin/env bash
# EWB Cloud Labs - Project 01: AWS VPC Peering
# Builds VPC A (10.10.0.0/16) + VPC B (10.20.0.0/16), three EC2 hosts, peering,
# peer routes, then runs the workbook's five tests and the controlled failure.
#
#   ./build-lab.sh keypair     generate ewb-lab locally and import the public key
#   ./build-lab.sh network     VPCs, subnets, IGW, route tables, security groups
#   ./build-lab.sh instances   bastion, App-A, App-B
#   ./build-lab.sh baseline    Test 01, the expected failure before peering
#   ./build-lab.sh peering     request, accept, add peer routes on both sides
#   ./build-lab.sh verify      Tests 02-05
#   ./build-lab.sh failtest    Test 06, controlled ICMP failure and recovery
#   ./build-lab.sh status      print the resource inventory
#   ./build-lab.sh all         keypair -> verify
#   ./build-lab.sh teardown    delete only what this script created
#
# Requires: AWS CLI v2 with credentials, curl, openssh. Region default ap-south-1.

set -euo pipefail
# Git-Bash rewrites argument values that start with / (e.g. DeviceName=/dev/xvda)
# into Windows paths. Tell MSYS runtime conversion to leave them alone.
export MSYS2_ARG_CONV_EXCL='*'

REGION="${REGION:-ap-south-1}"
AZ="${AZ:-ap-south-1a}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.micro}"
STUDENT="${STUDENT:-Baibhav Raj}"
SSH_USER="ec2-user"
KEY_NAME="ewb-lab"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="$ROOT/state.env"
EVIDENCE="$ROOT/evidence"
SECRETS="$ROOT/secrets"
PRIV_KEY="$SECRETS/$KEY_NAME.pem"

VPC_A_CIDR="10.10.0.0/16"
VPC_B_CIDR="10.20.0.0/16"
SUB_A_PUBLIC_CIDR="10.10.1.0/24"
SUB_A_PRIVATE_CIDR="10.10.2.0/24"
SUB_B_PRIVATE_CIDR="10.20.1.0/24"
BASTION_IP="10.10.1.10"
APPA_IP="10.10.2.10"
APPB_IP="10.20.1.10"

mkdir -p "$EVIDENCE" "$SECRETS"
touch "$STATE"
chmod 600 "$STATE" 2>/dev/null || true

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

remember() { # remember KEY VALUE
  grep -v "^$1=" "$STATE" > "$STATE.tmp" 2>/dev/null || true
  printf '%s=%s\n' "$1" "$2" >> "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}
lookup() { grep -m1 "^$1=" "$STATE" 2>/dev/null | cut -d= -f2- || true; }
need() { local v; v="$(lookup "$1")"; [ -n "$v" ] || die "$1 not in state.env - run ./build-lab.sh $2 first"; printf '%s' "$v"; }

tag_all() { # tag_all RESOURCE_ID NAME
  local id="$1" name="$2"
  aws ec2 create-tags --resources "$id" --output json > /dev/null \
    --tags "Key=Name,Value=$name" "Key=Project,Value=EWB-VPC-Peering" "Key=Student,Value=$STUDENT" "Key=Lab,Value=VPC-Peering"
}

latest_ami() {
  # newest Amazon Linux 2023 x86_64 AMI in the region (SSM is avoided because
  # Git-Bash rewrites leading-slash arguments into Windows paths)
  aws ec2 describe-images --region "$REGION" --owners amazon \
    --filters "Name=name,Values=al2023-ami-2023*-kernel-*-x86_64" "Name=state,Values=available" \
    --query 'reverse(sort_by(Images, &CreationDate))[0].ImageId' --output text
}

# Resumable "find by Name tag, else create" helpers --------------------------
aws_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

ensure_vpc() { # ensure_vpc NAME CIDR
  local id; id=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=tag:Name,Values=$1" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo None)
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    id=$(aws ec2 create-vpc --region "$REGION" --cidr-block "$2" --query 'Vpc.VpcId' --output text)
    tag_all "$id" "$1"
  fi
  printf '%s' "$id"
}

ensure_subnet() { # ensure_subnet NAME VPC_ID CIDR
  local id; id=$(aws ec2 describe-subnets --region "$REGION" --filters "Name=tag:Name,Values=$1" "Name=vpc-id,Values=$2" \
    --query 'Subnets[0].SubnetId' --output text)
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    id=$(aws ec2 create-subnet --region "$REGION" --vpc-id "$2" --cidr-block "$3" \
      --availability-zone "$AZ" --query 'Subnet.SubnetId' --output text)
    tag_all "$id" "$1"
  fi
  printf '%s' "$id"
}

ensure_rt() { # ensure_rt NAME VPC_ID
  local id; id=$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=tag:Name,Values=$1" "Name=vpc-id,Values=$2" \
    --query 'RouteTables[0].RouteTableId' --output text)
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    id=$(aws ec2 create-route-table --region "$REGION" --vpc-id "$2" --query 'RouteTable.RouteTableId' --output text)
    tag_all "$id" "$1"
  fi
  printf '%s' "$id"
}

ensure_igw() { # ensure_igw NAME VPC_ID
  local id; id=$(aws ec2 describe-internet-gateways --region "$REGION" --filters "Name=tag:Name,Values=$1" \
    --query 'InternetGateways[0].InternetGatewayId' --output text)
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    id=$(aws ec2 create-internet-gateway --region "$REGION" --query 'InternetGateway.InternetGatewayId' --output text)
    tag_all "$id" "$1"
  fi
  if [ -z "$(aws ec2 describe-internet-gateways --region "$REGION" --internet-gateway-ids "$id" \
      --filters "Name=attachment.vpc-id,Values=$2" --query 'InternetGateways[0].InternetGatewayId' --output text)" ]; then
    aws ec2 attach-internet-gateway --region "$REGION" --internet-gateway-id "$id" --vpc-id "$2"
  fi
  printf '%s' "$id"
}

ensure_sg() { # ensure_sg NAME VPC_ID
  local id; id=$(aws ec2 describe-security-groups --region "$REGION" --filters "Name=group-name,Values=$1" "Name=vpc-id,Values=$2" \
    --query 'SecurityGroups[0].GroupId' --output text)
  if [ "$id" = "None" ] || [ -z "$id" ]; then
    id=$(aws ec2 create-security-group --region "$REGION" --group-name "$1" --description "EWB lab $1" \
      --vpc-id "$2" --query 'GroupId' --output text)
    tag_all "$id" "$1"
  fi
  printf '%s' "$id"
}

associate_if_new() { # associate_if_new RT_ID SUBNET_ID
  if ! aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$1" \
      --query 'RouteTables[0].Associations[].SubnetId' --output text | tr '\t' '\n' | grep -qx "$2"; then
    aws ec2 associate-route-table --region "$REGION" --route-table-id "$1" --subnet-id "$2" > /dev/null
  fi
}

rule_exists() { # rule_exists SG_ID PROTOCOL FROM_PORT TO_PORT CIDR
  aws ec2 describe-security-groups --region "$REGION" --group-ids "$1" --output json \
    | python -c "
import json,sys
g=json.load(sys.stdin)['SecurityGroups'][0]
for p in g['IpPermissions']:
    for r in p.get('IpRanges',[]):
        print(p['IpProtocol'], p.get('FromPort'), p.get('ToPort'), r['CidrIp'])
" 2>/dev/null | grep -qx "$2 $3 $4 $5"
}

add_route() { # add_route RT_ID DEST CIDR_OR_PCX kind(igw|pcx)
  if aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$1" \
      --query "RouteTables[0].Routes[?DestinationCidrBlock=='$2'] | [0]" --output text | grep -q "$2"; then
    log "route $2 already present on $1"
    return 0
  fi
  if [ "$4" = "igw" ]; then
    aws ec2 create-route --region "$REGION" --route-table-id "$1" --destination-cidr-block "$2" --gateway-id "$3" > /dev/null
  else
    aws ec2 create-route --region "$REGION" --route-table-id "$1" --destination-cidr-block "$2" --vpc-peering-connection-id "$3" > /dev/null
  fi
}

dump_rt() { # dump_rt LABEL ROUTETABLE_ID  -> readable route evidence
  echo
  echo "### $1 = $2"
  aws ec2 describe-route-tables --region "$REGION" --route-table-ids "$2" --output json \
    | python -c "
import json,sys
d=json.load(sys.stdin)['RouteTables'][0]
print('  subnets: ' + ', '.join(a.get('SubnetId','(not associated)') for a in d.get('Associations',[])))
print('  %-17s %-24s %-12s %s' % ('DESTINATION','TARGET','ORIGIN','STATE'))
for r in d['Routes']:
    t=r.get('GatewayId') or r.get('NatGatewayId') or r.get('VpcPeeringConnectionId') or r.get('TransitGatewayId') or r.get('InstanceId') or r.get('NetworkInterfaceId') or '-'
    print('  %-17s %-24s %-12s %s' % (r.get('DestinationCidrBlock','?'), t, r.get('Origin','-'), r.get('State','-')))
"
}

dump_sg() { # dump_sg LABEL SG_ID
  echo
  echo "### $1 = $2 (inbound only)"
  aws ec2 describe-security-groups --region "$REGION" --group-ids "$2" --output json \
    | python -c "
import json,sys
g=json.load(sys.stdin)['SecurityGroups'][0]
print('  %-12s %-12s %s' % ('PORT','PROTOCOL','SOURCE'))
if not g['IpPermissions']: print('  (no inbound rules)')
for p in g['IpPermissions']:
    if p['IpProtocol']=='icmp':
        ports='type %s/code %s' % (p.get('FromPort'), p.get('ToPort'))
    else:
        ports=str(p.get('FromPort','all')) + ('' if p.get('FromPort')==p.get('ToPort') or not p.get('FromPort') else '-'+str(p['ToPort']))
    for r in p.get('IpRanges',[]):
        print('  %-12s %-12s %s' % (ports, p['IpProtocol'], r['CidrIp']))
    for r in p.get('UserIdGroupPairs',[]):
        print('  %-12s %-12s sg=%s' % (ports, p['IpProtocol'], r['GroupId']))
"
}

icmp_rule() { # icmp_rule authorize|revoke SG_ID CIDR   Echo request = type 8, code 0
  aws ec2 "$1"-security-group-ingress --region "$REGION" --group-id "$2" \
    --ip-permissions "IpProtocol=icmp,FromPort=8,ToPort=0,IpRanges=[{CidrIp=$3}]" > /dev/null
}

ingress() { # ingress SG_ID PROTOCOL PORT CIDR   (for icmp, PORT is ignored; Echo request is written)
  local sg="$1" proto="$2" port="$3" cidr="$4"
  if [ "$proto" = "icmp" ]; then
    if rule_exists "$sg" icmp 8 0 "$cidr"; then log "rule icmp echo from $cidr already on $sg"; return 0; fi
    icmp_rule authorize "$sg" "$cidr"
  else
    if rule_exists "$sg" "$proto" "$port" "$port" "$cidr"; then log "rule $proto/$port from $cidr already on $sg"; return 0; fi
    aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$sg" \
      --protocol "$proto" --port "$port" --cidr "$cidr" > /dev/null
  fi
}

# ---------------------------------------------------------------- key pair ----
cmd_keypair() {
  if [ ! -f "$PRIV_KEY" ]; then
    ssh-keygen -t rsa -b 2048 -m PEM -N '' -C "$KEY_NAME" -f "$PRIV_KEY" > /dev/null
  fi
  chmod 400 "$PRIV_KEY" 2>/dev/null || true
  local fp; fp="$(ssh-keygen -lf "$PRIV_KEY" | awk '{print $2}')"
  if [ "$(lookup KEY_FINGERPRINT)" != "$fp" ]; then
    aws ec2 import-key-pair --region "$REGION" --key-name "$KEY_NAME" \
      --public-key-material "fileb://$(aws_path "$PRIV_KEY.pub")" > /dev/null
    remember KEY_FINGERPRINT "$fp"
  fi
  log "key pair $KEY_NAME imported ($fp). Private key stays on this laptop: $PRIV_KEY"
}

# ---------------------------------------------------------------- network ----
cmd_network() {
  local myip="${MY_IP:-$(curl -s --max-time 15 ifconfig.me || curl -s --max-time 15 api.ipify.org)}"
  [ -n "$myip" ] || die "could not detect your public IPv4; export MY_IP=1.2.3.4 and retry"
  remember MY_IP "$myip"
  log "bastion will allow SSH from $myip/32 only (export MY_IP to change)"

  local vpc_a vpc_b sub_apub sub_apriv sub_bpriv igw rt_apub rt_apriv rt_bpriv sg_bastion sg_a sg_b

  log "VPC A ($VPC_A_CIDR) and VPC B ($VPC_B_CIDR)"
  vpc_a=$(ensure_vpc ewb-vpc-a "$VPC_A_CIDR")
  vpc_b=$(ensure_vpc ewb-vpc-b "$VPC_B_CIDR")

  log "subnets in $AZ"
  sub_apub=$(ensure_subnet ewb-a-public "$vpc_a" "$SUB_A_PUBLIC_CIDR")
  sub_apriv=$(ensure_subnet ewb-a-private "$vpc_a" "$SUB_A_PRIVATE_CIDR")
  sub_bpriv=$(ensure_subnet ewb-b-private "$vpc_b" "$SUB_B_PRIVATE_CIDR")

  log "internet gateway ewb-igw-a attached to VPC A"
  igw=$(ensure_igw ewb-igw-a "$vpc_a")

  log "route tables and explicit subnet associations"
  rt_apub=$(ensure_rt ewb-rt-a-public "$vpc_a")
  rt_apriv=$(ensure_rt ewb-rt-a-private "$vpc_a")
  rt_bpriv=$(ensure_rt ewb-rt-b-private "$vpc_b")
  associate_if_new "$rt_apub" "$sub_apub"
  associate_if_new "$rt_apriv" "$sub_apriv"
  associate_if_new "$rt_bpriv" "$sub_bpriv"

  log "public default route 0.0.0.0/0 -> ewb-igw-a (private tables keep only their local route)"
  add_route "$rt_apub" 0.0.0.0/0 "$igw" igw

  log "security groups"
  sg_bastion=$(ensure_sg ewb-sg-bastion "$vpc_a")
  sg_a=$(ensure_sg ewb-sg-app-a "$vpc_a")
  sg_b=$(ensure_sg ewb-sg-app-b "$vpc_b")

  ingress "$sg_bastion" tcp 22 "$myip/32"
  ingress "$sg_a" tcp 22 "$BASTION_IP/32"
  ingress "$sg_b" tcp 22 "$BASTION_IP/32"
  ingress "$sg_a" icmp 8 "$APPB_IP/32"
  ingress "$sg_b" icmp 8 "$APPA_IP/32"

  remember VPC_A "$vpc_a"; remember VPC_B "$vpc_b"
  remember SUB_A_PUBLIC "$sub_apub"; remember SUB_A_PRIVATE "$sub_apriv"; remember SUB_B_PRIVATE "$sub_bpriv"
  remember IGW_A "$igw"
  remember RT_A_PUBLIC "$rt_apub"; remember RT_A_PRIVATE "$rt_apriv"; remember RT_B_PRIVATE "$rt_bpriv"
  remember SG_BASTION "$sg_bastion"; remember SG_APP_A "$sg_a"; remember SG_APP_B "$sg_b"
  log "network ready"
}

# --------------------------------------------------------------- instances ----
launch() { # launch NAME SUBNET PRIVATE_IP SG PUBLIC_IP_FLAG
  local name="$1" subnet="$2" ip="$3" sg="$4" pub="$5"
  local args=(aws ec2 run-instances --region "$REGION" --image-id "$AMI" --instance-type "$INSTANCE_TYPE"
    --key-name "$KEY_NAME" --subnet-id "$subnet" --security-group-ids "$sg"
    --private-ip-address "$ip" --count 1
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=8,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}"
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled"
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$name},{Key=Project,Value=EWB-VPC-Peering},{Key=Student,Value=$STUDENT},{Key=Lab,Value=VPC-Peering}]"
    --query 'Instances[0].InstanceId' --output text)
  if [ "$pub" = "yes" ]; then args+=(--associate-public-ip-address); fi
  "${args[@]}"
}

cmd_instances() {
  local vpc_a vpc_b sub_apub sub_apriv sub_bpriv sgb sga sgb2 id ip
  AMI="$(latest_ami)"
  log "using Amazon Linux 2023 AMI $AMI"
  vpc_a="$(need VPC_A network)"; sub_apub="$(need SUB_A_PUBLIC network)"
  sub_apriv="$(need SUB_A_PRIVATE network)"; sub_bpriv="$(need SUB_B_PRIVATE network)"
  sgb="$(need SG_BASTION network)"; sga="$(need SG_APP_A network)"; sgb2="$(need SG_APP_B network)"

  log "launching ewb-bastion ($BASTION_IP, public)"
  id=$(launch ewb-bastion "$sub_apub" "$BASTION_IP" "$sgb" yes); remember I_BASTION "$id"
  log "launching ewb-app-a ($APPA_IP, private)"
  id=$(launch ewb-app-a "$sub_apriv" "$APPA_IP" "$sga" no); remember I_APP_A "$id"
  log "launching ewb-app-b ($APPB_IP, private)"
  id=$(launch ewb-app-b "$sub_bpriv" "$APPB_IP" "$sgb2" no); remember I_APP_B "$id"

  log "waiting for status checks (a few minutes)"
  aws ec2 wait instance-running --region "$REGION" --instance-ids "$(lookup I_BASTION)" "$(lookup I_APP_A)" "$(lookup I_APP_B)"
  aws ec2 wait instance-status-ok --region "$REGION" --instance-ids "$(lookup I_BASTION)" "$(lookup I_APP_A)" "$(lookup I_APP_B)"

  ip=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$(lookup I_BASTION)" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
  [ "$ip" != "None" ] || die "bastion has no public IPv4"
  remember BASTION_PUBLIC "$ip"
  log "bastion public IPv4: $ip"
  cmd_status
}

SSH_BASE=(-o BatchMode=yes -o ConnectTimeout=25 -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=$SECRETS/known_hosts" -i "$PRIV_KEY" -o IdentitiesOnly=yes)

proxy_for_bastion() {
  echo "ssh -o BatchMode=yes -o ConnectTimeout=25 -o StrictHostKeyChecking=accept-new -o \"UserKnownHostsFile=$SECRETS/known_hosts\" -i \"$PRIV_KEY\" -o IdentitiesOnly=yes -W %h:%p $SSH_USER@$(need BASTION_PUBLIC instances)"
}

run_local() { # run_local LABEL HOST_IP jump? CMD...
  local label="$1" host="$2" jump="$3"; shift 3
  local outf="$EVIDENCE/$label.txt"
  mkdir -p "$SECRETS"; touch "$SECRETS/known_hosts"
  {
    echo "# EWB VPC Peering evidence"
    echo "# test      : $label"
    echo "# run at    : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# from      : $(hostname)"
    echo "# command   : ssh $host  $*"
    echo
  } > "$outf"
  local -a cmd=(ssh "${SSH_BASE[@]}")
  if [ "$jump" = "jump" ]; then cmd+=(-o "ProxyCommand=$(proxy_for_bastion)"); fi
  cmd+=("$SSH_USER@$host" "$@")
  local rc=0
  "${cmd[@]}" >> "$outf" 2>&1 || rc=$?
  echo
  echo "[ssh exit code: $rc]" >> "$outf"
  cat "$outf"
  echo "--> saved to evidence/$label.txt"
}

# ---------------------------------------------------------------- baseline ----
cmd_baseline() {
  local bpub; bpub="$(need BASTION_PUBLIC instances)"
  mkdir -p "$SECRETS"; touch "$SECRETS/known_hosts"
  log "Test: SSH laptop -> bastion (VPC A local route, no peering needed)"
  run_local 01-ssh-bastion "$bpub" no 'hostname; hostname -I; uptime'
  log "Test: SSH laptop -> App-A through the bastion"
  run_local 02-ssh-app-a-via-bastion "$APPA_IP" jump 'hostname; hostname -I'
  log "Test 01 baseline: ping App-B from App-A - NO REPLIES expected"
  run_local 03-baseline-ping-app-a-to-app-b "$APPA_IP" jump "ping -c 4 $APPB_IP"
  log "Route tables now hold no peer routes, so that failure is the baseline."
}

# ----------------------------------------------------------------- peering ----
cmd_peering() {
  local vpc_a vpc_b pcx rt_apriv rt_bpriv rt_apub acct state
  vpc_a="$(need VPC_A network)"; vpc_b="$(need VPC_B network)"
  rt_apriv="$(need RT_A_PRIVATE network)"; rt_bpriv="$(need RT_B_PRIVATE network)"; rt_apub="$(need RT_A_PUBLIC network)"

  pcx="$(lookup PCX)"
  if [ -z "$pcx" ]; then
    acct="$(aws sts get-caller-identity --query Account --output text)"
    log "requesting ewb-a-b-peer (requester VPC A -> accepter VPC B)"
    pcx=$(aws ec2 create-vpc-peering-connection --region "$REGION" --vpc-id "$vpc_a" --peer-vpc-id "$vpc_b" \
      --peer-owner-id "$acct" --query 'VpcPeeringConnection.VpcPeeringConnectionId' --output text)
    tag_all "$pcx" ewb-a-b-peer
    log "accepting $pcx"
    aws ec2 accept-vpc-peering-connection --region "$REGION" --vpc-peering-connection-id "$pcx" > /dev/null
    remember PCX "$pcx"
  else
    log "peering $pcx already recorded"
  fi

  state=pending
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    state=$(aws ec2 describe-vpc-peering-connections --region "$REGION" --vpc-peering-connection-ids "$pcx" \
      --query 'VpcPeeringConnections[0].Status.Code' --output text)
    if [ "$state" = "active" ]; then break; fi
    sleep 3
  done
  [ "$state" = "active" ] || die "peering is $state, expected active"
  log "peering $pcx is Active"

  log "adding peer routes (private A -> VPC B, private B -> VPC A, public A -> VPC B for ProxyJump)"
  add_route "$rt_apriv" "$VPC_B_CIDR" "$pcx" pcx
  add_route "$rt_bpriv" "$VPC_A_CIDR" "$pcx" pcx
  add_route "$rt_apub" "$VPC_B_CIDR" "$pcx" pcx

  {
    echo "# route tables after peering  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# peering: $pcx"
    dump_rt ewb-rt-a-public "$rt_apub"
    dump_rt ewb-rt-a-private "$rt_apriv"
    dump_rt ewb-rt-b-private "$rt_bpriv"
  } > "$EVIDENCE/04-route-tables-after-peering.txt"
  cat "$EVIDENCE/04-route-tables-after-peering.txt"
  echo "--> saved to evidence/04-route-tables-after-peering.txt"
}

# ------------------------------------------------------------------ verify ----
cmd_verify() {
  local bpub; bpub="$(need BASTION_PUBLIC instances)"
  log "Test 02 forward: App-A -> App-B, 4 replies expected"
  run_local 05-forward-ping-app-a-to-app-b "$APPA_IP" jump "ping -c 4 $APPB_IP"
  log "Test 03 reverse: App-B -> App-A, 4 replies expected"
  run_local 06-reverse-ping-app-b-to-app-a "$APPB_IP" jump "ping -c 4 $APPA_IP"
  log "Test 04 private SSH to App-B through the bastion"
  run_local 07-ssh-app-b-via-bastion "$APPB_IP" jump 'hostname; hostname -I; whoami'
  log "Test 05 isolation: neither private host may have a public IPv4"
  {
    echo "# test 05 - public IP check  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    aws ec2 describe-instances --region "$REGION" \
      --instance-ids "$(lookup I_APP_A)" "$(lookup I_APP_B)" "$(lookup I_BASTION)" --output json \
      | python -c "
import json,sys
for r in json.load(sys.stdin)['Reservations']:
    for i in r['Instances']:
        n=[t['Value'] for t in i.get('Tags',[]) if t['Key']=='Name']
        pub=i.get('PublicIpAddress','(none)')
        print('  %-14s %-22s private=%-13s public=%s  %s' % (n[0] if n else '?', i['InstanceId'], i['PrivateIpAddress'], pub, i['State']['Name']))
"
    echo
    echo "# security group inbound rules"
    dump_sg ewb-sg-bastion "$(lookup SG_BASTION)"
    dump_sg ewb-sg-app-a "$(lookup SG_APP_A)"
    dump_sg ewb-sg-app-b "$(lookup SG_APP_B)"
  } > "$EVIDENCE/08-private-only-check.txt"
  cat "$EVIDENCE/08-private-only-check.txt"
  echo "--> saved to evidence/08-private-only-check.txt"
}

# ------------------------------------------------------- controlled failure ---
cmd_failtest() {
  local sg_b myip
  sg_b="$(need SG_APP_B network)"; myip="$(need MY_IP network)"
  log "revoking the App-B inbound ICMP Echo request rule from $APPA_IP/32 (SSH rule untouched)"
  icmp_rule revoke "$sg_b" "$APPA_IP/32"
  sleep 5
  log "expect NO REPLIES now"
  run_local 09-controlled-failure-ping "$APPA_IP" jump "ping -c 4 $APPB_IP"
  log "restoring the exact rule"
  ingress "$sg_b" icmp 8 "$APPA_IP/32"
  sleep 5
  log "expect 4 replies again"
  run_local 10-recovered-ping "$APPA_IP" jump "ping -c 4 $APPB_IP"
}

# ------------------------------------------------------------------ status ----
cmd_status() {
  {
    echo "resource            id                     extra"
    printf '%-18s %-22s %s\n' ewb-vpc-a      "$(lookup VPC_A)"         "$VPC_A_CIDR"
    printf '%-18s %-22s %s\n' ewb-vpc-b      "$(lookup VPC_B)"         "$VPC_B_CIDR"
    printf '%-18s %-22s %s\n' ewb-a-public   "$(lookup SUB_A_PUBLIC)"  "$SUB_A_PUBLIC_CIDR"
    printf '%-18s %-22s %s\n' ewb-a-private  "$(lookup SUB_A_PRIVATE)" "$SUB_A_PRIVATE_CIDR"
    printf '%-18s %-22s %s\n' ewb-b-private  "$(lookup SUB_B_PRIVATE)" "$SUB_B_PRIVATE_CIDR"
    printf '%-18s %-22s %s\n' ewb-igw-a      "$(lookup IGW_A)"         ""
    printf '%-18s %-22s %s\n' ewb-rt-a-public  "$(lookup RT_A_PUBLIC)"  ""
    printf '%-18s %-22s %s\n' ewb-rt-a-private "$(lookup RT_A_PRIVATE)" ""
    printf '%-18s %-22s %s\n' ewb-rt-b-private "$(lookup RT_B_PRIVATE)" ""
    printf '%-18s %-22s %s\n' ewb-sg-bastion "$(lookup SG_BASTION)"    "SSH from $(lookup MY_IP)/32"
    printf '%-18s %-22s %s\n' ewb-sg-app-a   "$(lookup SG_APP_A)"      "SSH+ICMP from bastion/App-B"
    printf '%-18s %-22s %s\n' ewb-sg-app-b   "$(lookup SG_APP_B)"      "SSH from bastion, ICMP from App-A"
    printf '%-18s %-22s %s\n' ewb-bastion    "$(lookup I_BASTION)"     "$(lookup BASTION_PUBLIC) / $BASTION_IP"
    printf '%-18s %-22s %s\n' ewb-app-a      "$(lookup I_APP_A)"       "$APPA_IP"
    printf '%-18s %-22s %s\n' ewb-app-b      "$(lookup I_APP_B)"       "$APPB_IP"
    printf '%-18s %-22s %s\n' ewb-a-b-peer   "$(lookup PCX)"           "run the tests for reachability"
  }
  printf 'peering state: '
  local p; p="$(lookup PCX)"
  if [ -n "$p" ]; then
    aws ec2 describe-vpc-peering-connections --region "$REGION" --vpc-peering-connection-ids "$p" \
      --query 'VpcPeeringConnections[0].Status.Code' --output text
  else
    printf 'not created yet\n'
  fi
}

# ----------------------------------------------------------------- teardown ---
cmd_teardown() {
  log "this deletes only resources recorded in state.env (Project=EWB-VPC-Peering)"
  local ids=() id k
  for k in I_BASTION I_APP_A I_APP_B; do
    id="$(lookup $k)"
    if [ -n "$id" ]; then ids+=("$id"); fi
  done
  if [ ${#ids[@]} -gt 0 ]; then
    log "terminating ${#ids[@]} instance(s)"
    aws ec2 terminate-instances --region "$REGION" --instance-ids "${ids[@]}" > /dev/null
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids "${ids[@]}"
  fi

  local pcx; pcx="$(lookup PCX)"
  if [ -n "$pcx" ]; then
    for rt in RT_A_PUBLIC RT_A_PRIVATE RT_B_PRIVATE; do
      local dst; case "$rt" in
        RT_A_PRIVATE) dst="$VPC_B_CIDR";;
        RT_B_PRIVATE) dst="$VPC_A_CIDR";;
        RT_A_PUBLIC)  dst="$VPC_B_CIDR";;
      esac
      aws ec2 delete-route --region "$REGION" --route-table-id "$(lookup $rt)" --destination-cidr-block "$dst" > /dev/null 2>&1 || true
    done
    log "deleting peering connection $pcx"
    aws ec2 delete-vpc-peering-connection --region "$REGION" --vpc-peering-connection-id "$pcx" > /dev/null
  fi

  for k in SG_BASTION SG_APP_A SG_APP_B; do
    id="$(lookup $k)"
    if [ -n "$id" ]; then log "deleting $id"; aws ec2 delete-security-group --region "$REGION" --group-id "$id" > /dev/null; fi
  done

  for k in SUB_A_PUBLIC SUB_A_PRIVATE SUB_B_PRIVATE; do
    id="$(lookup $k)"
    if [ -n "$id" ]; then log "deleting subnet $id"; aws ec2 delete-subnet --region "$REGION" --subnet-id "$id" > /dev/null; fi
  done
  for k in RT_A_PUBLIC RT_A_PRIVATE RT_B_PRIVATE; do
    id="$(lookup $k)"
    if [ -n "$id" ]; then log "deleting route table $id"; aws ec2 delete-route-table --region "$REGION" --route-table-id "$id" > /dev/null; fi
  done

  local igw; igw="$(lookup IGW_A)"
  if [ -n "$igw" ]; then
    aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$igw" --vpc-id "$(lookup VPC_A)" > /dev/null 2>&1 || true
    log "deleting internet gateway $igw"
    aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$igw" > /dev/null
  fi
  for k in VPC_A VPC_B; do
    id="$(lookup $k)"
    if [ -n "$id" ]; then log "deleting vpc $id"; aws ec2 delete-vpc --region "$REGION" --vpc-id "$id" > /dev/null; fi
  done

  if [ "${DELETE_KEYPAIR:-no}" = "yes" ]; then
    aws ec2 delete-key-pair --region "$REGION" --key-name "$KEY_NAME" > /dev/null || true
    log "deleted key pair $KEY_NAME (local file kept)"
  fi
  log "teardown complete - verify with: aws ec2 describe-instances --region $REGION and the Cost console"
}

cmd_sshconfig() {
  cp "$PRIV_KEY" "$HOME/.ssh/$KEY_NAME.pem" 2>/dev/null || true
  chmod 400 "$HOME/.ssh/$KEY_NAME.pem" 2>/dev/null || true
  cat > "$ROOT/ssh_config.snippet" <<EOF
# Copy the three Host blocks below into ~/.ssh/config
# (the key was placed at ~/.ssh/$KEY_NAME.pem - keep it private, never on an instance)
Host ewb-bastion
    HostName $(lookup BASTION_PUBLIC)
    User $SSH_USER
    IdentityFile ~/.ssh/$KEY_NAME.pem
    IdentitiesOnly yes

Host ewb-app-a
    HostName $APPA_IP
    User $SSH_USER
    IdentityFile ~/.ssh/$KEY_NAME.pem
    IdentitiesOnly yes
    ProxyJump ewb-bastion

Host ewb-app-b
    HostName $APPB_IP
    User $SSH_USER
    IdentityFile ~/.ssh/$KEY_NAME.pem
    IdentitiesOnly yes
    ProxyJump ewb-bastion
EOF
  log "wrote ssh_config.snippet (bastion public IP $(lookup BASTION_PUBLIC) - rerun this if the IP changes)"
}

cmd_all() {
  cmd_keypair; cmd_network; cmd_instances; cmd_baseline; cmd_peering; cmd_verify; cmd_sshconfig
}

case "${1:-help}" in
  keypair) cmd_keypair ;;
  network) cmd_network ;;
  instances) cmd_instances ;;
  baseline) cmd_baseline ;;
  peering) cmd_peering ;;
  verify) cmd_verify ;;
  failtest) cmd_failtest ;;
  status) cmd_status ;;
  teardown) cmd_teardown ;;
  sshconfig) cmd_sshconfig ;;
  all) cmd_all ;;
  *) sed -n '1,20p' "${BASH_SOURCE[0]}" ;;
esac

# Submission sheet — AWS VPC Peering (EWB Project 01)

Name: Baibhav Raj · Batch: ____________ · Region: ap-south-1 · Completed: 17 October 2026

| Workbook checklist item | Where it is | Marks | Done |
|---|---|---|---|
| Cover: name, batch, title, Region, date | top of this file and `README.md` | — | ✅ |
| Architecture diagram + inventory with real IDs and private IPs | `README.md` diagram, `evidence/00-inventory.txt` | 15 | ✅ |
| Subnet CIDRs and all three route tables with subnet associations | `evidence/04-route-tables-after-peering.txt` | 20 | ✅ |
| Active peering connection + inbound rules per security group | `evidence/00-inventory.txt`, `evidence/08-private-only-check.txt` | 20 | ✅ |
| Baseline failure, forward and reverse ping success, App-B SSH proof | `evidence/03`, `05`, `06`, `07` | 15 | ✅ |
| Controlled ICMP failure and recovery with explanation | `evidence/09`, `evidence/10`, README "The bug that taught me most" | 15 | ✅ |
| Cleanup evidence + what I learned | `evidence/11-cleanup.txt` (fill after teardown), notes below | 10 | ⬜ |

Console screenshots the workbook asks for (Checkpoint 01–04) — capture these from the console while the
lab is live, then add them to the report PDF as `BaibhavRaj_EWB_VPC_Peering.pdf`:

1. Checkpoint 01: two subnet associations + the public default route, private table local-only.
2. Checkpoint 02: three instance IDs, private IPs, bastion public IPv4, App-A/App-B public field empty.
3. Checkpoint 03: `ewb-a-b-peer` with **Active** and both VPC IDs.
4. Checkpoint 04: routes and associations for `ewb-rt-a-public`, `ewb-rt-a-private`, `ewb-rt-b-private`.

## Forward path / return path in one line each

* Forward: 10.10.2.10 → `ewb-rt-a-private` 10.20.0.0/16 → `pcx-043967053372c4309` → 10.20.1.10.
* Return: 10.20.1.10 replies to 10.10.2.10 → `ewb-rt-b-private` 10.10.0.0/16 → the same pcx → 10.10.2.10.

## What I learned

Peering is only the link; routes and security rules decide whether traffic may use it. I proved that
twice — once with the controlled rule deletion, and once with a real bug where `--protocol icmp --port 8`
created type 8 **code 8** while an Echo request needs code 0, so SSH crossed the peering connection
while every ping was dropped. Reading the console as "Active" would have told me nothing; one `tcpdump`
per side told me exactly where the packets died.

## Cleanup

Run `./build-lab.sh teardown`, then save the verification:

```bash
aws ec2 describe-instances --region ap-south-1 --filters "Name=tag:Project,Values=EWB-VPC-Peering" \
  --query 'Reservations[].Instances[].InstanceId' --output json > evidence/11-cleanup.txt
aws ec2 describe-vpcs --region ap-south-1 --filters "Name=tag:Project,Values=EWB-VPC-Peering" \
  --query 'Vpcs[*].VpcId' --output json >> evidence/11-cleanup.txt
```

Expected: two empty `[]`. Then check the Billing console for leftover chargeable resources and delete
the `ewb-lab` key pair (`./build-lab.sh` keeps the local private key; remove it yourself if you want).
No report contains a private key, password or token.

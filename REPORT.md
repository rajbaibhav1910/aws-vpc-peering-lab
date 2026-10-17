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
| Cleanup evidence + what I learned | `evidence/11-cleanup.txt`, notes below | 10 | ✅ |

Console screenshots for Checkpoints 01–04 had to be taken **during** the run — the resources are gone
now, so the CLI dumps in `evidence/` are what backs each checkpoint:

1. Checkpoint 01 (subnet associations + public default route, private table local-only):
   `evidence/04-route-tables-after-peering.txt`, read before the peering phase adds its routes.
2. Checkpoint 02 (three instance IDs, private IPs, bastion public IPv4, App-A/App-B public field empty):
   `evidence/08-private-only-check.txt`.
3. Checkpoint 03 (`ewb-a-b-peer` with **Active** and both VPC IDs): `evidence/00-inventory.txt`.
4. Checkpoint 04 (routes and associations for `ewb-rt-a-public`, `ewb-rt-a-private`, `ewb-rt-b-private`):
   `evidence/04-route-tables-after-peering.txt`.

If the instructor wants literal PNGs of the console, re-run `./build-lab.sh all` (about ₹7/hour) and
shoot them before teardown.

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

Ran `./build-lab.sh teardown` on 17 October 2026 at 15:41 IST. It terminated the three instances,
deleted `pcx-043967053372c4309` and the three peer routes, then the lab security groups, subnets,
custom route tables, `ewb-igw-a` and both VPCs — only the IDs it had recorded in `state.env`.

`evidence/11-cleanup.txt` holds the proof: every lab resource filtered by `Project=EWB-VPC-Peering`
returns empty, the peering connection reads `deleted`, all three instances read `terminated`, and the
pre-existing `smartgram-prod` VPC is untouched. The bastion's `13.206.123.132` was an auto-assigned
public IPv4, so it went with the instance; no Elastic IP and no EBS volume were left behind.

Deliberately kept: the `ewb-lab` key pair (costs nothing, and dropping it would break a re-run until
`state.env` is cleared). Remove it with
`aws ec2 delete-key-pair --region ap-south-1 --key-name ewb-lab`. The Billing console still needs a
look the next day, since usage reporting lags.
No report contains a private key, password or token.

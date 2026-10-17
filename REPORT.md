# Submission sheet — AWS VPC Peering (EWB Project 01)

Name: Raj Baibhav · Batch: ____________ · Region: ap-south-1 · Completed: 17 October 2026

The submission file is **`RajBaibhav_EWB_VPC_Peering.pdf`** (18 pages), built straight
from `evidence/` and `screenshots/`. Its sections follow the workbook checklist in order: §1 checklist,
§2 diagram + inventory, §3 route tables, §4 peering + security groups, §5 console screenshots,
§6 tests 01-05, §7 controlled failure and recovery, §8 forward/return path, §9 cleanup, §10 what I
learned, §11 the two bugs, §12 viva answers, §13 how to reproduce.

| Workbook checklist item | Where it is | Marks | Done |
|---|---|---|---|
| Cover: name, batch, title, Region, date | PDF cover, top of this file and `README.md` | — | ✅ |
| Architecture diagram + inventory with real IDs and private IPs | PDF §2, `README.md` diagram, `evidence/00-inventory.txt` | 15 | ✅ |
| Subnet CIDRs and all three route tables with subnet associations | PDF §3 + §5, `evidence/04-route-tables-after-peering.txt` | 20 | ✅ |
| Active peering connection + inbound rules per security group | PDF §4 + §5, `evidence/08-private-only-check.txt` | 20 | ✅ |
| Baseline failure, forward and reverse ping success, App-B SSH proof | PDF §6, `evidence/03`, `05`, `06`, `07` | 15 | ✅ |
| Controlled ICMP failure and recovery with explanation | PDF §7 + §11, `evidence/09`, `evidence/10` | 15 | ✅ |
| Cleanup evidence + what I learned | PDF §9-10, `evidence/11`, `evidence/13` | 10 | ✅ |

Console screenshots for Checkpoints 01-04 were captured from the AWS Management Console during
the second build (saved in `screenshots/` and embedded in `RajBaibhav_EWB_VPC_Peering.pdf`), backed
by the CLI output dumps in `evidence/`:

1. Checkpoint 01 (subnet associations, resource maps, public default route, private table local-only):
   - Screenshots: `screenshots/cp01-vpc-a-resource-map.png`, `cp01-vpc-b-resource-map.png`,
     `cp01-subnet-ewb-a-public.png`, `cp01-subnet-ewb-a-private.png`, `cp01-subnet-ewb-b-private.png`,
     `cp01-igw-attached-to-vpc-a.png`.
   - CLI proof: `evidence/04-route-tables-after-peering.txt`.
2. Checkpoint 02 (three instances, private IPs, bastion public IPv4, App-A/App-B public field empty):
   - Screenshots: `screenshots/cp02-instance-ewb-app-a.png`, `cp02-instance-ewb-app-b.png`.
   - CLI proof: `evidence/08-private-only-check.txt`.
3. Checkpoint 03 (`ewb-a-b-peer` with **Active** status, requester VPC A, and accepter VPC B):
   - Screenshot: `screenshots/cp03-peering-active.png`.
   - CLI proof: `evidence/00-inventory.txt`.
4. Checkpoint 04 (routes and associations for `ewb-rt-a-public`, `ewb-rt-a-private`, `ewb-rt-b-private`):
   - Screenshots: `screenshots/cp04-routes-ewb-rt-a-private.png`, `cp04-routes-ewb-rt-b-private.png`.
   - CLI proof: `evidence/04-route-tables-after-peering.txt`.

## Forward path / return path in one line each

* Forward: 10.10.2.10 → `ewb-rt-a-private` 10.20.0.0/16 → `pcx-0132d27205827aad2` → 10.20.1.10.
* Return: 10.20.1.10 replies to 10.10.2.10 → `ewb-rt-b-private` 10.10.0.0/16 → the same pcx → 10.10.2.10.
*(Build 1 used `pcx-043967053372c4309` with identical routing paths).*

## What I learned

1. **Routing and security groups govern the peering link**: Peering is only the pipe; routes and
   security rules decide whether traffic may use it. I proved that with the controlled rule deletion,
   and with a real bug where `--protocol icmp --port 8` created type 8 **code 8** while an Echo request
   needs code 0. SSH crossed the peering connection while every ping died silently at the hypervisor.
   Packet captures on both sides showed where the packets died.
2. **Stale host keys on rebuild**: Rebuilding the lab reused the same private IP addresses (`10.10.2.10`,
   `10.20.1.10`) on brand-new EC2 instances with new host keys. `ssh` aborted with host key verification
   failure (captured in `evidence/12-rebuild-hostkey-abort.txt`). The fix was updating the script to
   clear the lab hosts from `secrets/known_hosts` between runs.

## Cleanup

The lab was built twice to collect both CLI packet traces and console screenshots, and cleanly torn
down both times using `./build-lab.sh teardown`:
- **First teardown**: 17 October 2026 at 15:41 IST (`evidence/11-cleanup.txt`).
- **Second teardown**: 17 October 2026 at 18:18 IST (`evidence/13-final-account-state.txt`).

Every resource filtered by `Project=EWB-VPC-Peering` returns empty, the peering connection reads
`deleted`, instances read `terminated`, and the pre-existing `smartgram-prod` VPC was untouched.
The key pair `ewb-lab` is retained for future runs. No private keys, passwords, or credentials are committed.


#!/usr/bin/env python3
"""Build the submission PDF for EWB Project 01 from the evidence files.

  python make_pdf.py [--batch BATCH] [--out FILE.pdf]

Narrative lives in this file. Every test transcript, route table and security
group dump is read straight out of evidence/ so the report can never disagree
with what the lab actually printed. No key material is read or written.
"""

import argparse
import struct
import sys
from pathlib import Path

from fpdf import FPDF
from fpdf.enums import XPos, YPos

ROOT = Path(__file__).resolve().parent
EVIDENCE = ROOT / "evidence"
SCREENSHOTS = ROOT / "screenshots"
FONTS = Path("C:/Windows/Fonts")

STUDENT = "Baibhav Raj"
TITLE = "AWS VPC Peering - Connect two VPCs, prove private connectivity"
COURSE = "EWB Cloud Labs / AWS Architect Associate - Student Project 01"
REGION = "ap-south-1 (Mumbai)"
DATE = "17 October 2026"

# caption, evidence file, note that follows the transcript
TESTS = [
    ("Test 01 - Baseline failure", "03-baseline-ping-app-a-to-app-b.txt",
     "Host: ewb-app-a. Test: ping -c 4 10.20.1.10 before any peering exists. "
     "Result: 4 transmitted, 0 received, 100% loss. Expected, and the reference point for everything "
     "after. Transcript from the first build - the second attempt aborted on a stale host key, see section 7."),
    ("Test 02 - Forward path", "05-forward-ping-app-a-to-app-b.txt",
     "Host: ewb-app-a, after the peer routes. Result: 4 received, 0% loss. "
     "The request matched 10.20.0.0/16 in ewb-rt-a-private and crossed the peering connection."),
    ("Test 03 - Reverse path", "06-reverse-ping-app-b-to-app-a.txt",
     "Host: ewb-app-b. Result: 4 received, 0% loss. This only works because VPC B has the "
     "return route 10.10.0.0/16 pointing at the same peering connection."),
    ("Test 04 - Private SSH to App-B through the bastion", "07-ssh-app-b-via-bastion.txt",
     "Host: ewb-app-b, reached from the laptop with ProxyJump. Result: shell on ip-10-20-1-10 as ec2-user. "
     "No key was ever placed on the bastion."),
    ("Test 05 - Isolation and security groups", "08-private-only-check.txt",
     "Result: App-A and App-B show public=(none). Only ewb-sg-bastion faces the internet, "
     "and every app rule is a /32 host source."),
    ("Test 06a - Controlled failure", "09-controlled-failure-ping.txt",
     "Deleted only the inbound Echo request rule (type 8, code 0) from 10.10.2.10/32 on ewb-sg-app-b; "
     "the SSH rule stayed. Result: back to 100% loss while the peering connection still read Active. "
     "Transcript from the first build; same addresses, same rule, same outcome on the second."),
    ("Test 06b - Recovery", "10-recovered-ping.txt",
     "Restored that one identical rule. Result: 4 received again. This proves the security group, "
     "not routing, was the variable in step 06a."),
]


def read(name: str) -> str:
    path = EVIDENCE / name
    if not path.exists():
        sys.exit(f"missing evidence file: {path}")
    return path.read_text(encoding="utf-8", errors="replace").rstrip()


def png_size(path: Path):
    with open(path, "rb") as fh:
        head = fh.read(24)
    return struct.unpack(">II", head[16:24])


# Console screenshots taken while the second build was live (Checkpoint 01-04).
SHOTS = [
    ("cp01-vpc-a-resource-map.png",
     "Checkpoint 01 - VPC A resource map. Two subnets, three route tables, ewb-igw-a as the only "
     "network connection."),
    ("cp01-vpc-b-resource-map.png",
     "Checkpoint 01 - VPC B resource map. One private subnet, zero network connections, so no route "
     "out to the internet exists anywhere in this VPC."),
    ("cp01-subnet-ewb-a-public.png",
     "Checkpoint 01 - subnet ewb-a-public (10.10.1.0/24) is associated with the custom ewb-rt-a-public, "
     "not the main table."),
    ("cp01-subnet-ewb-a-private.png",
     "Checkpoint 01 - subnet ewb-a-private (10.10.2.0/24) is associated with ewb-rt-a-private "
     "(rtb-0bd505c2786b703ab)."),
    ("cp01-subnet-ewb-b-private.png",
     "Checkpoint 01 - subnet ewb-b-private (10.20.1.0/24) is associated with ewb-rt-b-private "
     "(rtb-0e1cc69e534cb466f)."),
    ("cp01-igw-attached-to-vpc-a.png",
     "Checkpoint 01 - igw-0169b40008fdaae98 is Attached to VPC A only, and carries the lab tags."),
    ("cp02-instance-ewb-app-a.png",
     "Checkpoint 02 - ewb-app-a, i-08cd773d457488487, private 10.10.2.10, Public IPv4 address empty, "
     "IMDSv2 required."),
    ("cp02-instance-ewb-app-b.png",
     "Checkpoint 02 - ewb-app-b, i-097b484f23a762579, private 10.20.1.10, Public IPv4 address empty. "
     "The bastion's own summary and public IPv4 13.126.70.86 are in evidence/08-private-only-check.txt."),
    ("cp03-peering-active.png",
     "Checkpoint 03 - pcx-0132d27205827aad2 status Active, requester vpc-0843b8bd344059014 / ewb-vpc-a "
     "(10.10.0.0/16), accepter vpc-097437c5c5b04cb2a / ewb-vpc-b (10.20.0.0/16), both in Mumbai."),
    ("cp04-routes-ewb-rt-a-private.png",
     "Checkpoint 04 - ewb-rt-a-private holds only the local route plus 10.20.0.0/16 to the peering "
     "connection. No default route, which is what keeps App-A private."),
    ("cp04-routes-ewb-rt-b-private.png",
     "Checkpoint 04 - ewb-rt-b-private is the return path: 10.10.0.0/16 to the same peering connection. "
     "ewb-rt-a-public (0.0.0.0/0 to the IGW plus 10.20.0.0/16 to the pcx) is dumped in evidence/04."),
]


def screenshot(pdf, fname, caption):
    path = SCREENSHOTS / fname
    if not path.exists():
        sys.exit(f"missing screenshot: {path}")
    pw, ph = png_size(path)
    width = pdf.epw
    height = width * ph / pw
    if pdf.get_y() + height + 14 > pdf.page_break_trigger:
        pdf.add_page()
    pdf.set_font("body", "B", 8.5)
    pdf.set_text_color(40)
    pdf.multi_cell(0, 4.2, caption, new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.set_text_color(0)
    pdf.ln(1.5)
    pdf.image(str(path), w=width)
    pdf.ln(5)



class Report(FPDF):
    def header(self):
        if self.page_no() == 1:
            return
        self.set_font("body", "B", 8)
        self.set_text_color(110)
        self.cell(0, 5, f"{STUDENT} - AWS VPC Peering - {REGION}", new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.set_draw_color(200)
        self.line(self.l_margin, 16, self.w - self.r_margin, 16)
        self.set_text_color(0)
        self.ln(3)

    def footer(self):
        self.set_y(-14)
        self.set_font("body", "", 8)
        self.set_text_color(120)
        self.cell(0, 5, f"Page {self.page_no()}/{{nb}}", align="C")
        self.set_text_color(0)

    # -- building blocks -------------------------------------------------
    def h1(self, text):
        self.set_font("body", "B", 13)
        self.set_fill_color(235, 240, 246)
        self.cell(0, 9, f"  {text}", fill=True, new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.ln(2.5)

    def h2(self, text):
        self.set_font("body", "B", 10.5)
        self.ln(1.5)
        self.cell(0, 6, text, new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.ln(1)

    def body(self, text, size=9.5):
        self.set_font("body", "", size)
        self.multi_cell(0, 4.4, text, new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.ln(1.5)

    def bullets(self, items, size=9.5):
        self.set_font("body", "", size)
        for it in items:
            self.set_x(self.l_margin + 3)
            self.multi_cell(self.epw - 3, 4.4, f"- {it}", new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.ln(1.5)

    def mono(self, text, size=7.2):
        self.set_font("mono", "", size)
        self.set_fill_color(246, 247, 248)
        self.set_draw_color(190)
        lines = [(l.expandtabs(6).rstrip() or " ") for l in text.splitlines()] or [" "]
        needed = len(lines) * 3.6
        space = self.page_break_trigger - self.get_y()
        if needed > space and space < self.h * 0.4:
            self.add_page()
        for line in lines:
            if self.get_y() > self.page_break_trigger - 6:
                self.add_page()
            self.multi_cell(self.epw, 3.6, line.expandtabs(6).rstrip() or " ", fill=True, border="LT",
                            new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.cell(self.epw, 1.2, "", border="B", fill=True,
                  new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.set_draw_color(0)
        self.ln(2.5)

    def table(self, headers, rows, widths, size=8.5):
        if sum(widths) > self.epw + 0.5:
            scale = self.epw / sum(widths)
            widths = [w * scale for w in widths]
        lh = 4.6

        def draw_head():
            self.set_font("body", "B", size)
            self.set_fill_color(225, 232, 240)
            top = self.get_y()
            for h, w in zip(headers, widths):
                self.multi_cell(w, lh, h, border=1, fill=True,
                                new_x=XPos.RIGHT, new_y=YPos.TOP)
            self.set_xy(self.l_margin, top + lh)

        draw_head()
        self.set_font("body", "", size)
        for row in rows:
            if self.get_y() > self.page_break_trigger - 14:
                self.add_page()
                draw_head()
                self.set_font("body", "", size)
            top = self.get_y()
            lines = []
            for val, w in zip(row, widths):
                out = self.multi_cell(w, lh, str(val), dry_run=True, output="LINES")
                lines.append(len(out))
            height = max(lines) * lh
            for val, w in zip(row, widths):
                self.multi_cell(w, lh, str(val), border=1,
                                new_x=XPos.RIGHT, new_y=YPos.TOP)
            self.set_xy(self.l_margin, top + height)
        self.ln(3)


def diagram(pdf):
    art = """+--------------------------------+      +--------------------------------+
| VPC A             10.10.0.0/16 |      | VPC B             10.20.0.0/16 |
| internet gateway: ewb-igw-a    |      | no internet gateway            |
|                                |      |                                |
| ewb-a-public    10.10.1.0/24   |      | ewb-b-private   10.20.1.0/24   |
|   ewb-bastion      10.10.1.10  |      |   ewb-app-b        10.20.1.10  |
|   public IPv4: yes             |      |   public IPv4: none            |
|                                |      |                                |
| ewb-a-private   10.10.2.0/24   |      |                                |
|   ewb-app-a        10.10.2.10  |      |                                |
|   public IPv4: none            |      |                                |
+----------------+---------------+      +----------------+---------------+
                 |                                       |
     10.20.0.0/16 => pcx                    10.10.0.0/16 => pcx
                 |                                       |
                 +--------- peering connection ----------+

Paths under test
  laptop --TCP 22 (my public IP /32, through ewb-igw-a)--> ewb-bastion
  ewb-bastion --VPC A local route--> ewb-app-a            (works before peering)
  ewb-bastion --10.20.0.0/16 => pcx--> ewb-app-b          (ProxyJump, needs the peering route)
  ewb-app-a <--ICMP echo, 4 of 4 each way--> ewb-app-b    (private IPs only)"""
    pdf.mono(art, size=6.8)


def cover(pdf, batch):
    pdf.add_page()
    pdf.ln(24)
    pdf.set_font("body", "B", 22)
    pdf.multi_cell(0, 11, "AWS VPC Peering", new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.set_font("body", "", 13)
    pdf.ln(1)
    pdf.multi_cell(0, 7, "Two VPCs, one private connection, and the evidence that it works",
                 new_x=XPos.LMARGIN, new_y=YPos.NEXT)
    pdf.ln(8)
    pdf.set_draw_color(40, 90, 150)
    pdf.set_line_width(0.7)
    pdf.line(pdf.l_margin, pdf.get_y(), pdf.w - pdf.r_margin, pdf.get_y())
    pdf.set_line_width(0.2)
    pdf.set_draw_color(0)
    pdf.ln(10)
    rows = [
        ("Name", STUDENT),
        ("Batch", batch),
        ("Project", "01 - AWS VPC Peering (build / test / explain)"),
        ("Course", COURSE),
        ("Region", REGION),
        ("Completed", DATE),
        ("Result", "6 of 6 workbook tests passed, teardown verified clean"),
        ("Evidence", "13 CLI transcripts and 11 console screenshots, all in the public repo"),
    ]
    pdf.table(["Field", "Value"], rows, [34, 140], size=10)
    pdf.body(
        "I built the whole environment through the AWS CLI instead of clicking, ran every test the "
        "workbook asks for, and kept the raw terminal output behind each claim. The lab starts with a "
        "ping that fails on purpose, ends with a security group rule removed and restored to show "
        "which control actually matters, and along the way it hit two real bugs: an ICMP type/code "
        "mistake that took packet captures on both sides to find, and a stale SSH host key that only "
        "appeared when the lab was rebuilt."
    )


def body_pages(pdf):
    pdf.add_page()
    pdf.h1("1. Architecture and address plan")
    pdf.body(
        "One internet entry point (the bastion), two private workloads, and a peering connection that "
        "carries traffic only between them. VPC B has no internet gateway, so the only path to App-B is "
        "through the bastion, and the only path between the apps is their private addresses."
    )
    diagram(pdf)
    inv = read("00-inventory.txt")
    pdf.h2("Resource inventory with real IDs")
    pdf.mono(inv, size=7.0)

    pdf.add_page()
    pdf.h1("2. Route tables")
    pdf.body(
        "Three custom tables, each explicitly associated with its own subnet. The private tables hold "
        "only the local VPC route until peering is added - there is no default route anywhere in VPC B, "
        "and none in the private subnet of VPC A either."
    )
    pdf.mono(read("04-route-tables-after-peering.txt"), size=7.4)
    pdf.h2("Why the public subnet also needs a peering route")
    pdf.body(
        "ProxyJump does not tunnel a single TCP stream end to end. The bastion opens its own connection "
        "to App-B, so the route lookup happens in the bastion's subnet table. 10.20.0.0/16 is more "
        "specific than 0.0.0.0/0, so that traffic goes to the peering connection instead of the internet. "
        "Without this route, ssh ewb-app-b would time out at the bastion while App-A to App-B still pinged."
    )

    pdf.add_page()
    pdf.h1("3. Security rules")
    pdf.body(
        "Inbound only; outbound stays allow-all and the NACLs stay default, so routing and security "
        "groups are the only variables under test. Every source is a /32 host, never 0.0.0.0/0."
    )
    pdf.table(
        ["Group", "Inbound rule", "Why that source"],
        [
            ["ewb-sg-bastion", "TCP 22 from my public IPv4 /32", "only my laptop touches the one public host"],
            ["ewb-sg-app-a", "TCP 22 from 10.10.1.10/32", "administration comes from the bastion only"],
            ["ewb-sg-app-a", "ICMP Echo (type 8, code 0) from 10.20.1.10/32", "App-B's reverse ping"],
            ["ewb-sg-app-b", "TCP 22 from 10.10.1.10/32", "ProxyJump sends the bastion's private IP, not mine"],
            ["ewb-sg-app-b", "ICMP Echo (type 8, code 0) from 10.10.2.10/32", "App-A's forward ping"],
        ],
        [40, 66, 78],
    )
    pdf.h1("4. Test results")
    pdf.body(
        "Acceptance criteria met, in workbook order. Each block below is the real transcript, labelled "
        "with host, test and result."
    )
    pdf.table(
        ["#", "Test", "Host / command", "Result"],
        [
            ["01", "Baseline before peering", "App-A: ping -c 4 10.20.1.10", "0 received, 100% loss"],
            ["02", "Forward path", "App-A: ping -c 4 10.20.1.10", "4 received, 0% loss"],
            ["03", "Reverse path", "App-B: ping -c 4 10.10.2.10", "4 received, 0% loss"],
            ["04", "Private SSH", "laptop -> bastion -> App-B", "shell as ec2-user"],
            ["05", "Isolation", "EC2 details, both app hosts", "public=(none) on both"],
            ["06", "Controlled failure", "delete one ICMP rule, restore it", "100% loss, then 4 replies"],
        ],
        [10, 44, 62, 68],
    )

    for caption, fname, note in TESTS:
        if pdf.get_y() > pdf.page_break_trigger - 40:
            pdf.add_page()
        pdf.h2(caption)
        pdf.mono(read(fname), size=7.2)
        pdf.body(note, size=9)

    pdf.add_page()
    pdf.h1("5. Console screenshots (Checkpoint 01-04)")
    pdf.body(
        "Captured from the console while the environment was live, in workbook order. The second build "
        "is shown here, so the IDs match evidence/00-inventory.txt; the transcripts in section 4 come "
        "from the same addressing on both builds."
    )
    for fname, cap in SHOTS:
        screenshot(pdf, fname, cap)

    pdf.add_page()
    pdf.h1("6. Forward path and return path")
    pdf.bullets([
        "Forward: App-A 10.10.2.10 sends to 10.20.1.10. Its subnet table matches 10.20.0.0/16, target "
        "pcx-0132d27205827aad2. The packet crosses into VPC B and arrives at App-B's ENI, where the "
        "inbound Echo request rule lets it in.",
        "Return: App-B replies to 10.10.2.10. That is a fresh lookup in ewb-rt-b-private, which needs its "
        "own route 10.10.0.0/16 back over the same peering connection. Security groups are stateful, so "
        "the reply is accepted without a rule of its own.",
        "Remove either route and ping shows 100% loss while the connection still reads Active. A one-way "
        "route is the single easiest mistake to make in this lab.",
    ])

    pdf.h1("7. The bugs that taught me the most")
    pdf.body(
        "Peering was Active, all three route tables were correct, and SSH from the bastion to App-B "
        "worked - yet every ping failed in both directions. So I captured traffic on each side: tcpdump "
        "on App-A showed four echo requests leaving, and tcpdump on App-B showed zero packets arriving. "
        "The gap was in the hypervisor, before the guest ever saw the traffic."
    )
    pdf.body(
        "The cause was my own security group rule. The AWS CLI shortcut --protocol icmp --port 8 wrote "
        "it as type 8, code 8. An Echo request is code 0, so nothing matched. In the console, picking "
        "'Custom ICMP - IPv4 / Echo request' gives type 8 code 0 and would have been right from the "
        "start. The fix was an explicit --ip-permissions with FromPort=8 and ToPort=0. Two lessons: an "
        "Active peering connection proves nothing about traffic being permitted, and one packet capture "
        "per side tells you which side is lying where a screenshot would not."
    )
    pdf.h2("The second one: stale host keys on the rebuild")
    pdf.body(
        "Rebuilding the same lab a second time broke two tests before peering was even involved. The new "
        "instances came back with the same private IPs (10.10.2.10, 10.20.1.10) but fresh SSH host keys, "
        "so StrictHostKeyChecking refused the connection and the run died with exit 255. The transcript "
        "is kept as evidence/12-rebuild-hostkey-abort.txt because it is a real result, just not a lab "
        "result. The script now clears those IPs from secrets/known_hosts before the SSH phases, and "
        "run_local aborts the phase instead of quietly saving a host-key error as if it were a test."
    )
    pdf.body(
        "The wider point: reusing addresses across builds is fine for the VPC design and dangerous for "
        "SSH trust. A rebuild is a new host, and it should be treated like one."
    )

    pdf.h1("8. Viva answers")
    answers = [
        ("Why is the return route needed?",
         "A ping is two trips. The reply to 10.10.2.10 is a new route lookup inside VPC B, which only "
         "knows its own CIDR until 10.10.0.0/16 points at the peering connection. Statefulness covers "
         "the security group, not the routing."),
        ("Why is App-B's SSH source the bastion's private IP?",
         "The source of a packet is whoever sent it. ProxyJump makes the bastion open the connection "
         "from its primary private address 10.10.1.10. My laptop's public IP stops at the bastion and "
         "never crosses the peering link."),
        ("Why does Active peering not guarantee a successful ping?",
         "The connection is only a link. Reachability still needs routes on both sides, the right "
         "inbound rule including the ICMP code, permissive NACLs, and running instances with the right "
         "destination IP."),
        ("Can VPC B use VPC A's internet gateway over peering?",
         "No. An internet gateway serves the VPC it is attached to, and transitive routing through a "
         "peering connection is not supported. That is why dnf update fails on the private hosts, and "
         "why that failure is not a peering bug."),
    ]
    for q, a in answers:
        pdf.set_font("body", "B", 9.5)
        pdf.multi_cell(0, 4.6, q, new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        pdf.body(a, size=9.5)
    pdf.body(
        "Core concept: peering is one-to-one and non-transitive. A-B plus A-C never creates B-C. Routes "
        "and rules stay editable after acceptance, and swapping either VPC means a new connection."
    )

    pdf.add_page()
    pdf.h1("9. Cleanup evidence")
    pdf.body(
        "Teardown ran from the same script that built the lab, so it deleted only the IDs it had "
        "recorded. That matters here: the account also runs a production stack, and nothing outside "
        "the lab tags was touched."
    )
    pdf.mono(read("11-cleanup.txt"), size=7.2)
    pdf.body(
        "That was the first teardown, at 15:43 IST. The lab was built again for the console screenshots "
        "and torn down a second time; the check below ran after that, straight from the account."
    )
    pdf.mono(read("13-final-account-state.txt"), size=7.2)

    pdf.h1("10. What I learned")
    pdf.bullets([
        "Peering is only the link; route tables and security rules decide whether traffic may use it.",
        "Plan CIDRs before anything exists. 10.10.0.0/16 and 10.20.0.0/16 do not overlap, which is the "
        "reason peering was even allowed - separate /24 subnet ranges would not have fixed overlapping VPCs.",
        "Explicit subnet associations are worth naming. A route in the wrong table looks identical in a "
        "screenshot and does nothing.",
        "Test the negative case on purpose. The controlled failure taught me more than the passing ping.",
        "When a test fails and the console says healthy, capture packets at both ends instead of "
        "guessing which layer to blame.",
        "A rebuild is a new set of hosts even when the IPs match. Reusing private addresses means "
        "reusing SSH host keys that no longer belong to anything.",
        "Costs need an owner. t3.micro in three places plus one public IPv4 is cheap, but it is real "
        "money, so the script ends with teardown and a check that the account is clear.",
    ])

    pdf.h1("11. Reproduce it")
    pdf.body(
        "GitHub: github.com/rajbaibhav1910/aws-vpc-peering-lab - one script, phased so each checkpoint "
        "can be captured in order. ./build-lab.sh all builds through the tests, failtest runs the "
        "controlled failure, teardown removes everything. Every phase finds its resources by Name tag "
        "before creating anything, so re-running is safe. The private key never left my laptop and is "
        "not in the repository."
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--batch", default="____________", help="your batch, printed on the cover")
    ap.add_argument("--out", default=str(ROOT / "BaibhavRaj_EWB_VPC_Peering.pdf"))
    args = ap.parse_args()

    pdf = Report("P", "mm", "A4")
    pdf.set_margins(18, 16, 18)
    for style, path in (("", FONTS / "arial.ttf"), ("B", FONTS / "arialbd.ttf")):
        if not path.exists():
            sys.exit(f"font not found: {path}")
        pdf.add_font("body", style, str(path))
    courier = FONTS / "cour.ttf"
    if not courier.exists():
        sys.exit(f"font not found: {courier}")
    pdf.add_font("mono", "", str(courier))

    cover(pdf, args.batch)
    body_pages(pdf)
    pdf.output(args.out)
    pages = pdf.page_no() if hasattr(pdf, "page_no") else len(pdf.pages)
    print(f"wrote {args.out} ({pages} pages)")


if __name__ == "__main__":
    main()

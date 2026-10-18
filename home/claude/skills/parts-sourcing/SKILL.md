---
name: parts-sourcing
description: Find, compare and shortlist electronic and mechanical parts for projects built in Poland or the EU. Covers TME, Botland, Kamami, Farnell, Mouser, DigiKey and JLCPCB basic parts, with stock, price in PLN incl. 23% VAT, and a BOM output. Use when the user asks where to buy a part, wants alternates for an EOL or out-of-stock component, needs a BOM priced, or asks about a fastener, connector or module for a KiCad or FreeCAD project. Does not place orders.
---

# Parts Sourcing

Goal: a shortlist of purchasable parts with a clear reason for each pick, not a list of every listing.

## 1. Pin down the requirement first

Before searching, have these (ask only for what is missing and affects the choice):

- Function and electrical spec: voltage, current, tolerance, temperature range, interface.
- Package or footprint, and whether it is for hand soldering, reflow or a fab that does assembly.
- Quantity: prototype (1 to 10) or production (100+). This decides distributor vs. JLCPCB vs. bulk.
- Anything that disqualifies a part, such as a required certification or a no-lead rule.

If the spec is ambiguous in a way that changes the part (5 V vs 3.3 V logic, through-hole vs SMD), stop and ask.

## 2. Search order

Check in this order and stop once there is a solid pick. Keep the search to what changes the decision.

1. **TME** (tme.eu): default for passives, semiconductors, connectors and fasteners in PL/EU. Good stock depth, PLN pricing, next-day delivery in Poland.
2. **Botland** and **Kamami**: modules, dev boards, sensors, hobby parts. Often the only sensible choice for Raspberry Pi, Arduino and ESP ecosystem boards.
3. **Farnell / element14** and **Mouser**: when TME lacks the part or the user needs a datasheet-grade variant. Prices here are often in EUR or USD, so convert and say so.
4. **DigiKey**: fallback when nothing above has it. Shipping and customs are real costs for PL buyers.
5. **JLCPCB parts library**: only if the fab will do SMT assembly. Prefer **Basic** parts (no extra setup fee). Flag **Extended** parts as an extra per-reel fee.

Do not recommend AliExpress or generic marketplace listings by default. Use them only when the user asks for them, and say the risks: long lead times, unverified specs, counterfeit ICs and no reliable datasheet. For safety-critical or mains-connected parts, never.

## 3. Verify before recommending

For each candidate, check and report:

- **Datasheet** exists from the manufacturer, and the key parameters match the spec.
- **Stock** at the distributor, and the lead time if out of stock.
- **Lifecycle**: active, not NRND, EOL or obsolete. Anything NRND needs an alternate in the same answer.
- **Footprint** matches the KiCad library entry. Name the footprint, do not assume it.

If the search tools return nothing reliable (blocked page, login wall, stale cache), say so. Do not invent a stock number or a price.

## 4. Price

- Show unit price at the quantity the user needs, not the cheapest tier.
- Convert to PLN and state the rate and date used.
- Show the total with 23% VAT, and show the net separately if the user is a VAT-registered company.
- Add shipping only when it is known. Mark it as an estimate otherwise.

## 5. Output

Default to a table with one row per part:

| Ref | Part (MPN) | Manufacturer | Package | Supplier | SKU | Stock | Unit PLN (net) | Qty | Total PLN (gross) | Notes |
|-----|------------|--------------|---------|----------|-----|-------|----------------|-----|-------------------|-------|

Then a short list of alternates, one line each, with the reason they are not the first pick.

For a full BOM, also offer a CSV with the same columns, ready for KiCad's BOM export or a spreadsheet. Keep the reference designators from the schematic.

## 6. Rules

- Never place an order, add to cart, log in or enter payment or address details. Purchases are the user's own action.
- Never store supplier API keys in the repo. In this NixOS setup, keys go through sops-nix, and the skill reads them from the environment.
- Fasteners: metric only, ISO, DIN or PN-EN. Name the standard (DIN 912, DIN 934, DIN 125). No UNF or UNC.
- Keep answers short. One recommendation per line item, and the reason is one clause.

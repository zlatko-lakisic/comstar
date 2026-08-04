# Presence / people (voice)

## People

| Spoken | Entity |
|--------|--------|
| Zlatko | `person.zlatko_lakisic` |
| Adna | `person.adna_zujo_lakisic` |
| Ibrica | `person.ibrica_lakisic` |
| Admin / MD | `person.md_admin` |

State is typically `home` / `not_home` or a zone name. Speak naturally
(“Zlatko is home”).

## Zones / areas

HA areas include living_room, kitchen, office, garage, driveway, front_yard,
back_yard, basement, bedrooms, hallways, mostar, etc. Use area-filtered
GetLiveContext when asking “is anyone in the office”.

Do not invent GPS or precise location beyond person/zone state.

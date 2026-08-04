# Irrigation / garden (voice)

Call HA tools first. Prefer irrigation sensors over guessing.

## Controllers (Orbit / BHyve-style)

East lawn timer, front yard controller, flower garden / back lawn timer,
vegetable garden timer. Prefer **7d minute sensors** for “how much watered”.

## 7‑day minutes (preferred for summaries)

| Spoken | Entity |
|--------|--------|
| East lawn | `sensor.irrigation_7d_east_lawn_minutes` |
| East flower bed | `sensor.irrigation_7d_east_flower_bed_minutes` |
| Front yard | `sensor.irrigation_7d_front_yard_minutes` |
| Back lawn | `sensor.irrigation_7d_back_lawn_minutes` |
| Kitchen slope | `sensor.irrigation_7d_slope_kitchen_left_minutes` |
| Peppers & kale | `sensor.irrigation_7d_peppers_kale_minutes` |
| Tomato | `sensor.irrigation_7d_tomato_minutes` |
| Zucchini & eggplant | `sensor.irrigation_7d_zucchini_eggplant_minutes` |
| Top flowers | `sensor.irrigation_7d_top_flowers_minutes` |
| Zone 4 | `sensor.irrigation_7d_zone_4_minutes` |

Companion non-`_minutes` sensors exist under the same `irrigation_7d_*` prefix.

## Last run / zone history

Example: `sensor.east_lawn_timer_east_lawn_zone_zone_history` (state = timestamp;
attrs may include `run_time`, `status`).

## Smart watering / program switches (examples)

- East: `switch.east_lawn_timer_east_lawn_zone_smart_watering`,
  `switch.east_lawn_timer_flower_bed_zone_smart_watering`, programs
- Back / flower: `switch.flower_garden_back_lawn_time_*_smart_watering`, programs
- Vegetable: `switch.vegitable_garden_timer_*` (note spelling `vegitable`)

## Rain delay

- `switch.east_lawn_timer_rain_delay`
- `switch.front_yard_controller_rain_delay`
- `switch.flower_garden_back_lawn_time_rain_delay`
- `switch.vegitable_garden_timer_rain_delay`

## Soil moisture

`sensor.garden_controller_soil_moisture_1` … `_6`

## Manual watering climate

`climate.bhyve_manual_watering`

## Spoken style

Zone names, minutes this week, soil %, rain delay on/off. Confirm zone + duration
before starting a program/switch.

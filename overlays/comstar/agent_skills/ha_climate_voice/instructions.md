# Climate / weather (voice)

## Thermostats

| Spoken | Entity |
|--------|--------|
| Living room | `climate.new_livingroom_climate` |
| Nest / second | `climate.150633094697190_climate` |

Report current temp, setpoint, HVAC mode, humidity if available.

## Weather

- `weather.home`, `weather.forecast_home` — condition, temp, forecast summary.

## Energy (limited)

TV / Nest energy: `sensor.tv_energy*`, `sensor.tv_energy_meter*`,
`sensor.150633094697190_*_energy_consumption`. Not a full home energy dashboard.

## Indoor environment

Humidity / temp sensors by area when exposed. Prefer area-friendly names
(living room, master bedroom, office, basement).

## Irrigation climate link

`climate.bhyve_manual_watering` belongs with irrigation; if asked about watering
climate, still use irrigation skill entities.

Spoken: one room or outdoor summary, not a full dashboard dump.

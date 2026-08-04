# Security / access / cameras (voice)

Call HA tools before claiming locked/unlocked or motion.

## Locks

| Spoken | Entity |
|--------|--------|
| Front door | `lock.front_door` |
| Office door | `lock.office_door` |
| Door to garage | `lock.door_to_garage` |
| Back door | `lock.back_door` |

## Garage door

`cover.garage_door_door` — open / closed / opening.

## Motion

| Spoken | Entity |
|--------|--------|
| Driveway | `binary_sensor.driveway_motion` (+ `_2`) |
| Back yard | `binary_sensor.back_yard_motion` (+ `_2`) |
| Front door | `binary_sensor.front_door_motion` (+ `_2`) |
| West / east side | `binary_sensor.west_side_motion*`, `east_side_motion` |
| Garden N/S | `binary_sensor.garden_north_motion`, `garden_south_motion` |
| Closet presence | `binary_sensor.master_bedroom_closet_presence_sensor_motion` |

## Cameras (Frigate / generic)

`camera.driveway`, `camera.front_door`, `camera.back_yard`, `camera.west_side`,
`camera.east_side`, `camera.garden_north`, `camera.garden_south` (and `*_2` variants).
Voice usually reports motion/FPS, not video frames.

## Frigate health

FPS: `sensor.driveway_frigate_fps`, `back_yard_`, `garden_north_`, `garden_south_`,
`west_side_frigate_fps`. Container: `sensor.frigate_state`, CPU/memory.
Plate: `sensor.frigate_plate_recognizer_*`.

Do not invent detections — only live tool state.

## Flood / outdoor lights as security

`light.flood_lights`, garden IR lights — only when explicitly requested.

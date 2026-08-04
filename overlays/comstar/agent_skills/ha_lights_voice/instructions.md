# Lights / outdoor plugs (voice)

Confirm entity via tools, then call light turn_on/off / brightness if available.

## Named lights (examples)

- Garage: `light.garage_light`, `light.garage_door_light`, `light.garage_hallway_light_switch`
- Outdoor: `light.flood_lights`, `light.front_walkway_steps`, `light.garden_lights_light`,
  `light.garden_lights_light_2`, patio plugs `light.smart_patio_plug_light*`
- Basement / kitchenette: `light.basement_light`, `light.kitchenette_light`,
  `light.kitchenette_counter_light_light`, `light.kitchen_countertop_lights_light`
- Closets: master bedroom closet top/bottom, `light.closet_light`
- AP LEDs: `light.ap_back_yard_led`, `light.ap_bottom_floor_led`, `light.ap_top_floor_led`
- Garden IR: `light.garden_south_ir_light_0`, `light.garden_north_ir_light_0`
- Master bedroom switch: `light.master_bedroom_master_bedroom_light_switch`
- Dimmer: `light.in_wall_paddle_dimmer_no_ntrl_700s`

Ambiguous “lights” → ask which room/area (garage, garden, kitchenette, flood, etc.).
Do not toggle IR/camera lights unless explicitly requested.

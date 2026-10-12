-- Overflows: only those discharging now until county scale (zoom 10), then all of them.
update core.map_layer set hot_only_below = 10 where code = 'overflows';

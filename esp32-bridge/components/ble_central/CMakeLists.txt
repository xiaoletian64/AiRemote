# ble_central/
idf_component_register(
    SRCS "ble_central.c"
    INCLUDE_DIRS "include"
    REQUIRES
        "bt"
        "app_events"
        "adpcm"
        "voice_dsp"
)

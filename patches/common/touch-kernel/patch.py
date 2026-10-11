"""Check the shared touch driver personality; this does not patch the kernel.

Both generated DeviceTrees use multi-touch,n48, including N49.
"""

PATCH = {
    'kind': 'prelink-feature',
    'bundle_id': 'com.apple.driver.AppleMultitouchSPIC1F57',
    'matching': {
        'IOClass': 'AppleMultitouchN1SPI',
        'IONameMatch': ['multi-touch,n48'],
        'mt-merge-personality': 'C1F57,2',
    },
    'physical_validation': False,
}

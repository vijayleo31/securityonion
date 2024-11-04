'''
Add Virtual Node Beacon

This beacon monitors for creation or modification of files matching a specific pattern
and sends the contents of the files up to the Salt Master's event bus, including
the hypervisor and nodetype extracted from the file path.

Configuration:

    beacons:
      add_virtual_node_beacon:
        - base_path: /path/to/files/*

If base_path is not specified, it defaults to '/opt/so/saltstack/local/salt/hypervisor/hosts/*/add_*'
'''

import os
import glob
import logging
import re

log = logging.getLogger(__name__)

__virtualname__ = 'add_virtual_node_beacon'
DEFAULT_BASE_PATH = '/opt/so/saltstack/local/salt/hypervisor/hosts/*/add_*'

def __virtual__():
    '''
    Return the virtual name of the beacon.
    '''
    return __virtualname__

def validate(config):
    '''
    Validate the beacon configuration.

    Args:
        config (list): Configuration of the beacon.

    Returns:
        tuple: A tuple of (bool, str) indicating success and message.
    '''
    if not isinstance(config, list):
        return False, 'Configuration for add_virtual_node_beacon must be a list of dictionaries'
    for item in config:
        if not isinstance(item, dict):
            return False, 'Each item in configuration must be a dictionary'
        if 'base_path' in item and not isinstance(item['base_path'], str):
            return False, 'base_path must be a string'
    return True, 'Valid beacon configuration'

def beacon(config):
    '''
    Monitor for creation or modification of files and send events.

    Args:
        config (list): Configuration of the beacon.

    Returns:
        list: A list of events to send to the Salt Master.
    '''
    if 'add_virtual_node_beacon' not in __context__:
        __context__['add_virtual_node_beacon'] = {}

    ret = []

    for item in config:
        base_path = item.get('base_path', DEFAULT_BASE_PATH)
        file_list = glob.glob(base_path)

        log.debug('Starting add_virtual_node_beacon. Found %d files matching pattern %s', len(file_list), base_path)

        for file_path in file_list:
            try:
                mtime = os.path.getmtime(file_path)
                prev_mtime = __context__['add_virtual_node_beacon'].get(file_path, 0)
                if mtime > prev_mtime:
                    log.info('File %s is new or modified', file_path)
                    with open(file_path, 'r') as f:
                        contents = f.read()

                    data = {}
                    # Parse the contents of the file
                    for line in contents.splitlines():
                        if ':' in line:
                            key, value = line.split(':', 1)
                            data[key.strip()] = value.strip()
                        else:
                            log.warning('Line in file %s does not contain colon: %s', file_path, line)

                    # Extract hypervisor and nodetype from the file path
                    match = re.match(r'^.*/hosts/(?P<hypervisor>[^/]+)/add_(?P<nodetype>[^/]+)$', file_path)
                    if match:
                        data['hypervisor'] = match.group('hypervisor')
                        data['nodetype'] = match.group('nodetype')
                    else:
                        log.warning('Unable to extract hypervisor and nodetype from file path: %s', file_path)
                        data['hypervisor'] = None
                        data['nodetype'] = None

                    event = {'tag': f'add_virtual_node/{os.path.basename(file_path)}', 'data': data}
                    ret.append(event)
                    __context__['add_virtual_node_beacon'][file_path] = mtime
                else:
                    log.debug('File %s has not been modified since last check', file_path)
            except FileNotFoundError:
                log.warning('File not found: %s', file_path)
            except PermissionError:
                log.error('Permission denied when accessing file: %s', file_path)
            except Exception as e:
                log.error('Error processing file %s: %s', file_path, str(e))

    return ret

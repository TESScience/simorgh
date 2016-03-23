"""
This module contains:
  - A schemas object representing parsed JSON-schemas from the schemas directory
  - A SchemaBasedRESTEndpoint class definition, for defining REST endpoints based on JSON-Schema
  - A rest-endpoints object which is suitable for use with cherrypy as a server object
"""
__author__ = 'Matthew Wampler-Doty'

import os.path
import json
import collections

import pkg_resources
import cherrypy
import jsonschema

from database import db


def dictionary_map(f, dictionary):
    """
    Map a function over some nested dictionaries, returning a new dictionary
    :param f: function (taking a dictionary as an argument)
    :param dictionary: dict
    :return: dict
    """
    return f({k: dictionary_map(f, v) if isinstance(v, dict) else v
              for k, v in dictionary.iteritems()})


schema_dir = 'schemas'


def load_resource_schema(*args, **kwargs):
    """
    Load a JSON from a resource in a specified directory relative to this one
    :param schema: str
    :return: dict
    """
    loaded_schema = json.loads(pkg_resources.resource_string(__name__, os.path.join(schema_dir, *args)))
    if 'check' not in kwargs or kwargs['check']:
        jsonschema.validate(loaded_schema, schema_schema)
    return loaded_schema


schema_schema = load_resource_schema('meta', 'schema_schema.json', check=False)
jsonschema.validate(schema_schema, schema_schema)


# TODO: this doesn't handle fragment identifiers properly
def load_meta_schema(dictionary):
    """
    Load any meta schema specified in a schema dictionary
    :param dictionary: dict
    :return: dict
    """
    return load_resource_schema(dictionary[u'$ref']) \
        if u'$ref' in dictionary and '.json' in dictionary[u'$ref'] \
        else dictionary


# Parse all of the schema data from the schemas subdirectory and make a dictionary but not its subdirectories

schemas = dictionary_map(load_meta_schema, {os.path.splitext(schema)[0]: load_resource_schema(schema)
                                            for schema in pkg_resources.resource_listdir(__name__, schema_dir)
                                            if ".json" in schema})


class SchemaBasedRESTEndpoint(object):
    exposed = True

    def __init__(self, schema):
        self.schema = schema
        self.name = schema['properties']['type']['enum'][0]

    __init__.exposed = False

    def process_data(self, data):
        """Process data from a POST or PUT call"""
        import jsonschema
        jsonschema.validate(data, self.schema)
        return db.insert(data)

    process_data.exposed = False

    @cherrypy.tools.json_out()
    def GET(self):
        from tinydb import where
        return db.search(where('type') == self.name)

    @cherrypy.tools.json_in()
    @cherrypy.tools.json_out()
    def POST(self):
        return self.process_data(cherrypy.request.json)

    @cherrypy.tools.json_in()
    @cherrypy.tools.json_out()
    def PUT(self):
        return self.process_data(cherrypy.request.json)


# Create a rest_endpoints object suitable for CherryPy
rest_endpoints = (collections.namedtuple('DataRESTEndpoints', ['exposed', 'favicon_ico', 'conf'] + schemas.keys()))(
    exposed=True,
    # This needs to be set apparently...
    favicon_ico=None,
    conf={
        os.path.join('/', schema_name): {
            'request.dispatch': cherrypy.dispatch.MethodDispatcher(),
            'tools.response_headers.on': True,
            'tools.response_headers.headers': [('Content-Type', 'application/json')],
        } for schema_name in schemas},
    **{schema_name: SchemaBasedRESTEndpoint(schema) for schema_name, schema in schemas.iteritems()})

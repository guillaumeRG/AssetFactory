"""Importer contract tests with a strict mock of Unreal (no editor/GPU needed)."""
import importlib.util
import json
import os
from pathlib import Path
import sys
import types

import pytest

ROOT = Path(__file__).resolve().parents[1]


class Object:
    def __init__(self, **properties):
        self.properties = properties

    def set_editor_property(self, name, value):
        if name not in self.properties:
            raise AttributeError(name)
        self.properties[name] = value

    def get_editor_property(self, name):
        return self.properties[name]


class Asset:
    def __init__(self, path):
        self.path = path

    def get_path_name(self):
        return self.path


class StaticMesh(Asset):
    pass


class Material(Asset):
    pass


class Texture(Asset):
    pass


class Task(Object):
    def __init__(self):
        super().__init__(filename=None, destination_path=None, destination_name=None,
                         automated=False, async_=True, replace_existing=True,
                         save=False, options=None, imported_object_paths=[])
        self.objects = []
        self.waited = False

    def get_objects(self):
        self.waited = True
        return self.objects


class FbxOptions(Object):
    def __init__(self):
        super().__init__(import_mesh=False, import_as_skeletal=True, mesh_type=None,
                         import_materials=None, import_textures=None,
                         static_mesh_import_data=Object(combine_meshes=None,
                             generate_lightmap_u_vs=None, auto_generate_collision=None))


class Stack:
    def __init__(self):
        self.pipelines = []

    def add_pipeline(self, pipeline):
        self.pipelines.append(pipeline)


class GltfPipeline:
    pass


def make_unreal(modern=True):
    unreal = types.ModuleType('unreal')
    unreal.calls = []
    unreal.logs = []
    unreal.assets = {}
    unreal.saved = []
    unreal.no_objects = False
    unreal.material_only = False
    unreal.result_paths_only = False
    unreal.save_ok = True
    unreal.AssetImportTask = Task
    unreal.FbxImportUI = FbxOptions
    unreal.FBXImportType = types.SimpleNamespace(FBXIT_STATIC_MESH='static')
    unreal.StaticMesh = StaticMesh
    unreal.InterchangeGLTFPipeline = GltfPipeline
    unreal.InterchangePipelineStackOverride = Stack
    unreal.InterchangeMaterialSearchLocation = types.SimpleNamespace(LOCAL='local')
    if modern:
        unreal.InterchangeCombineStaticMeshesBehavior = types.SimpleNamespace(ALL='all', DO_NOT_COMBINE='none')

    class GenericPipeline(Object):
        def __init__(self):
            mesh_props = dict(import_static_meshes=None, import_skeletal_meshes=None,
                              generate_lightmap_u_vs=None, collision=None)
            mesh_props['combine_static_meshes_behavior' if modern else 'combine_static_meshes'] = None
            super().__init__(asset_name=None, use_source_name_for_asset=None,
                             asset_type_sub_folders=None, scene_name_sub_folder=None,
                             mesh_pipeline=Object(**mesh_props),
                             animation_pipeline=Object(import_animations=None),
                             material_pipeline=Object(import_materials=None, search_location=None,
                                 texture_pipeline=Object(import_textures=None)))

    unreal.InterchangeGenericAssetsPipeline = GenericPipeline
    for name in ('log', 'log_warning', 'log_error'):
        setattr(unreal, name, unreal.logs.append)

    def import_tasks(tasks):
        unreal.calls.extend(tasks)
        for task in tasks:
            opts = task.properties['options']
            name = (opts.pipelines[0].properties['asset_name']
                    if isinstance(opts, Stack) else task.properties['destination_name'])
            base = task.properties['destination_path'] + '/' + name
            assets = [StaticMesh(base + '.' + name),
                      Material(base + '_material.' + name + '_material'),
                      Texture(base + '_texture.' + name + '_texture')]
            if unreal.material_only:
                assets = assets[1:]
            if unreal.no_objects:
                assets = []
            task.objects = [] if unreal.result_paths_only else assets
            task.properties['imported_object_paths'] = [a.path for a in assets]
            unreal.assets.update({a.path: a for a in assets})

    def save_asset(path, only_if_is_dirty):
        assert only_if_is_dirty is False
        unreal.saved.append(path)
        return unreal.save_ok

    unreal.AssetToolsHelpers = types.SimpleNamespace(
        get_asset_tools=lambda: types.SimpleNamespace(import_asset_tasks=import_tasks))
    unreal.EditorAssetLibrary = types.SimpleNamespace(
        load_asset=lambda path: unreal.assets.get(path), save_asset=save_asset)
    return unreal


@pytest.fixture
def loaded(monkeypatch):
    def load(modern=True):
        fake = make_unreal(modern)
        monkeypatch.setitem(sys.modules, 'unreal', fake)
        spec = importlib.util.spec_from_file_location('af_import_under_test', ROOT/'unreal/import_asset.py')
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod, fake
    return load


def make_job(tmp_path, monkeypatch, extension='.glb', legacy=False, settings=None, asset_id='chair'):
    source = tmp_path/('chair.v2' + extension)
    source.write_bytes(b'fixture: mock importer does not parse geometry')
    job = dict(status='running', assetId=asset_id, category='Furniture/Seats',
               contentRoot='/Game/AssetFactory', importSettings=settings or {},
               error=None, importedObjectPaths=[])
    job['fbxPath' if legacy else 'sourcePath'] = str(source)
    path = tmp_path/'job.json'
    path.write_text(json.dumps(job), encoding='utf-8-sig')
    monkeypatch.setenv('ASSET_FACTORY_IMPORT_JOB', str(path))
    return path, source


@pytest.mark.parametrize('modern', [True, False])
def test_glb_import_uses_interchange_and_saves_real_objects(loaded, tmp_path, monkeypatch, modern):
    mod, fake = loaded(modern)
    path, source = make_job(tmp_path, monkeypatch)
    original = source.read_bytes()
    mod.main()
    result = json.loads(path.read_text())
    assert result['status'] == 'completed'
    assert result['importer'] == 'interchange-glb'
    assert result['destinationPath'] == '/Game/AssetFactory/Furniture/Seats/chair'
    assert len(result['meshObjectPaths']) == 1
    assert len(result['importedObjectPaths']) == len(fake.saved) == 3
    task = fake.calls[0]
    assert task.waited and task.properties['async_'] is False
    assert task.properties['automated'] and task.properties['save']
    stack = task.properties['options']
    assert isinstance(stack, Stack)
    assert isinstance(stack.pipelines[1], GltfPipeline)
    pipeline = stack.pipelines[0].properties
    assert pipeline['asset_name'] == 'chair'
    assert pipeline['material_pipeline'].properties['import_materials'] is True
    assert pipeline['material_pipeline'].properties['texture_pipeline'].properties['import_textures'] is True
    assert source.read_bytes() == original


@pytest.mark.parametrize('modern', [True, False])
def test_explicit_glb_settings_are_respected(loaded, modern):
    mod, _ = loaded(modern)
    settings = dict(combineMeshes=False, importMaterials=False, importTextures=False,
                    generateLightmapUVs=False, autoGenerateCollision=False)
    stack, keepalive = mod.make_glb_options(settings, 'tank')
    p = stack.pipelines[0].properties
    mesh = p['mesh_pipeline'].properties
    assert mesh['combine_static_meshes_behavior' if modern else 'combine_static_meshes'] == ('none' if modern else False)
    assert mesh['generate_lightmap_u_vs'] is False and mesh['collision'] is False
    assert p['material_pipeline'].properties['import_materials'] is False
    assert p['material_pipeline'].properties['texture_pipeline'].properties['import_textures'] is False
    assert keepalive == tuple(stack.pipelines)


def test_legacy_fbx_job_and_options_preserved(loaded, tmp_path, monkeypatch):
    mod, fake = loaded()
    path, _ = make_job(tmp_path, monkeypatch, extension='.fbx', legacy=True)
    mod.main()
    result = json.loads(path.read_text())
    assert result['status'] == 'completed' and result['importer'] == 'fbx'
    assert result['destinationPath'] == '/Game/AssetFactory/Furniture/Seats'
    opts = fake.calls[0].properties['options']
    assert isinstance(opts, FbxOptions)
    assert opts.properties['import_materials'] is False
    assert opts.properties['import_textures'] is False
    assert opts.properties['import_mesh'] is True
    assert opts.properties['import_as_skeletal'] is False
    assert opts.properties['static_mesh_import_data'].properties == dict(
        combine_meshes=True, generate_lightmap_u_vs=True, auto_generate_collision=True)


def test_optional_subfolder_can_be_disabled(loaded, tmp_path, monkeypatch):
    mod, _ = loaded()
    path, _ = make_job(tmp_path, monkeypatch, settings={'assetSubfolder': False})
    mod.main()
    assert json.loads(path.read_text())['destinationPath'] == '/Game/AssetFactory/Furniture/Seats'


@pytest.mark.parametrize('failure, message', [('no_objects','no imported object'),
                                            ('material_only','no StaticMesh'),
                                            ('save_ok','could not save')])
def test_incomplete_import_is_failure_not_success(loaded, tmp_path, monkeypatch, failure, message):
    mod, fake = loaded()
    setattr(fake, failure, failure != 'save_ok')
    path, source = make_job(tmp_path, monkeypatch)
    with pytest.raises(RuntimeError, match=message):
        mod.main()
    job = json.loads(path.read_text())
    assert job['status'] == 'failed' and message in job['error']
    assert source.is_file()


def test_paths_only_result_is_loaded_and_validated(loaded, tmp_path, monkeypatch):
    mod, fake = loaded()
    fake.result_paths_only = True
    path, _ = make_job(tmp_path, monkeypatch)
    mod.main()
    assert json.loads(path.read_text())['status'] == 'completed'


def test_missing_interchange_is_clear_failure(loaded, tmp_path, monkeypatch):
    mod, fake = loaded()
    del fake.InterchangePipelineStackOverride
    path, _ = make_job(tmp_path, monkeypatch)
    with pytest.raises(RuntimeError, match='Interchange plugins'):
        mod.main()
    assert not fake.calls
    assert json.loads(path.read_text())['status'] == 'failed'


@pytest.mark.parametrize('extension, default_id', [('.GLB', 'chair_v2'), ('.glb','chair_v2'), ('.fbx','chair_v2')])
def test_case_insensitive_format_and_default_asset_name(loaded, tmp_path, monkeypatch, extension, default_id):
    mod, _ = loaded()
    path, _ = make_job(tmp_path, monkeypatch, extension=extension, asset_id='')
    mod.main()
    assert json.loads(path.read_text())['assetName'] == default_id


@pytest.mark.parametrize('state, message', [('missing','not found'), ('empty','empty'), ('unsupported','Unsupported')])
def test_source_errors_happen_before_import(loaded, tmp_path, monkeypatch, state, message):
    mod, fake = loaded()
    path, source = make_job(tmp_path, monkeypatch, extension='.obj' if state=='unsupported' else '.glb')
    if state == 'missing':
        source.unlink()
    elif state == 'empty':
        source.write_bytes(b'')
    with pytest.raises(RuntimeError, match=message):
        mod.main()
    assert not fake.calls
    assert json.loads(path.read_text())['status'] == 'failed'


@pytest.mark.parametrize('root', ['/GameOther', '/Engine', '/Game/../Other', '/Game//Seats', 'C:/Game'])
def test_destination_cannot_escape_game(loaded, root):
    mod, _ = loaded()
    with pytest.raises(ValueError):
        mod.validate_content_root(root)


def test_string_boolean_cannot_enable_an_option(loaded, tmp_path, monkeypatch):
    mod, fake = loaded()
    path, _ = make_job(tmp_path, monkeypatch, settings={'replaceExisting': 'false'})
    with pytest.raises(RuntimeError, match='JSON boolean'):
        mod.main()
    assert not fake.calls


def test_missing_source_field(loaded):
    mod, _ = loaded()
    with pytest.raises(ValueError, match='missing sourcePath'):
        mod.resolve_source({})


def test_get_objects_without_paths_still_works(loaded):
    mod, _ = loaded()
    task = Task()
    task.objects = [StaticMesh('/Game/Test/Mesh.Mesh')]
    objects, meshes = mod.collect_imported_objects(task)
    assert list(objects) == meshes == ['/Game/Test/Mesh.Mesh']


def test_required_option_failure_is_not_ignored(loaded):
    mod, _ = loaded()
    with pytest.raises(RuntimeError, match='Cannot configure'):
        mod.require_set(Object(), 'import_textures', True)

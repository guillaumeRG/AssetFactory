"""Unit tests with a simulated Blender API; no engine/GPU downloads or writes."""
import contextlib
import importlib.util
import io
import json
import math
from pathlib import Path
import struct
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]


class Vector:
    def __init__(self, values):
        self.values = list(values)

    def __iter__(self):
        return iter(self.values)

    def __getitem__(self, index):
        return self.values[index]

    x = property(lambda self: self.values[0])
    y = property(lambda self: self.values[1])
    z = property(lambda self: self.values[2])


class Matrix:
    def __init__(self, rows):
        self.rows = [list(row) for row in rows]

    @classmethod
    def Identity(cls, size):
        return cls([[float(i == j) for j in range(size)] for i in range(size)])

    @classmethod
    def Scale(cls, factor, size):
        result = cls.Identity(size)
        for i in range(size - 1):
            result.rows[i][i] = factor
        return result

    @classmethod
    def Translation(cls, offset):
        result = cls.Identity(4)
        for i, value in enumerate(offset):
            result.rows[i][3] = value
        return result

    def __matmul__(self, other):
        if isinstance(other, Vector):
            values = other.values + [1.0]
            return Vector([sum(a * b for a, b in zip(row, values)) for row in self.rows][:3])
        return Matrix([[sum(self.rows[i][k] * other.rows[k][j] for k in range(4))
                        for j in range(4)] for i in range(4)])

    def copy(self):
        return Matrix(self.rows)


class Mesh:
    def __init__(self, vertices, users=1):
        self.vertices = [Vector(v) for v in vertices]
        self.users = users
        self.polygons = [object()]
        self.uv_marker = object()
        self.material_marker = object()

    def copy(self):
        copied = Mesh([v.values for v in self.vertices])
        copied.uv_marker = self.uv_marker
        copied.material_marker = self.material_marker
        return copied

    def transform(self, matrix):
        self.vertices = [matrix @ v for v in self.vertices]

    def update(self):
        pass


class Object:
    def __init__(self, mesh, matrix=None, parent=None):
        self.data = mesh
        self.matrix_world = matrix or Matrix.Identity(4)
        self.parent = parent
        self.type = "MESH"
        self.selected = False

    @property
    def bound_box(self):
        v = self.data.vertices
        return [(x, y, z)
                for x in [min(p.x for p in v), max(p.x for p in v)]
                for y in [min(p.y for p in v), max(p.y for p in v)]
                for z in [min(p.z for p in v), max(p.z for p in v)]]

    def select_set(self, value):
        self.selected = value


def glb_bytes(document):
    data = json.dumps(document).encode()
    data += b" " * (-len(data) % 4)
    return struct.pack("<4sII", b"glTF", 2, 20 + len(data)) + struct.pack("<II", len(data), 0x4E4F534A) + data


class MeshTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.directory = Path(self.tmp.name)
        self.calls = []
        self.objects = [Object(Mesh([(-1, -1, -1), (1, 1, 1)]))]
        self.output_document = {"meshes": [{}], "materials": [{}], "textures": [{}], "images": [{"bufferView": 0}]}
        self.bpy = types.SimpleNamespace(
            context=types.SimpleNamespace(
                scene=types.SimpleNamespace(objects=self.objects, unit_settings=types.SimpleNamespace()),
                view_layer=types.SimpleNamespace(update=lambda: None, objects=types.SimpleNamespace(active=None))),
            ops=types.SimpleNamespace(
                object=types.SimpleNamespace(select_all=lambda **k: None, delete=lambda **k: None),
                wm=types.SimpleNamespace(obj_import=self.import_obj, obj_export=self.export_obj),
                import_scene=types.SimpleNamespace(gltf=self.import_glb),
                export_scene=types.SimpleNamespace(gltf=self.export_glb, fbx=self.export_fbx)))
        bm = types.SimpleNamespace(from_mesh=lambda m: None, to_mesh=lambda m: None, free=lambda: None, faces=[])
        self.bmesh = types.SimpleNamespace(new=lambda: bm, ops=types.SimpleNamespace(recalc_face_normals=lambda *a, **k: self.calls.append("normals")))
        spec = importlib.util.spec_from_file_location("af_process_mesh", ROOT / "blender/scripts/process-mesh.py")
        self.module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, {"bpy": self.bpy, "bmesh": self.bmesh, "mathutils": types.SimpleNamespace(Vector=Vector, Matrix=Matrix)}):
            spec.loader.exec_module(self.module)

    def tearDown(self):
        self.tmp.cleanup()

    def import_obj(self, **kwargs):
        self.calls.append(("import_obj", kwargs))

    def import_glb(self, **kwargs):
        self.calls.append(("import_glb", kwargs))

    def export_obj(self, **kwargs):
        self.calls.append(("export_obj", kwargs))
        Path(kwargs["filepath"]).write_text("v 0 0 0\n")

    def export_glb(self, **kwargs):
        self.calls.append(("export_glb", kwargs))
        Path(kwargs["filepath"]).write_bytes(glb_bytes(self.output_document))

    def export_fbx(self, **kwargs):
        self.calls.append(("export_fbx", kwargs))
        Path(kwargs["filepath"]).write_bytes(b"FBX stub")

    def run_main(self, input_suffix, output_suffix, fbx=False):
        source = self.directory / ("input" + input_suffix)
        source.write_bytes(glb_bytes(self.output_document) if input_suffix == ".glb" else b"v 0 0 0\n")
        output = self.directory / ("chair.v2" + output_suffix)
        args = ["blender", "--", "--input", str(source), "--output", str(output), "--target-height", "1.5"]
        if fbx:
            args += ["--fbx-output", str(self.directory / "mesh.fbx")]
        with patch.object(sys, "argv", args), contextlib.redirect_stdout(io.StringIO()) as captured:
            self.module.main()
        result = [s for s in captured.getvalue().splitlines() if s.startswith("[RESULT_JSON] ")][-1]
        return json.loads(result.split(" ", 1)[1]), source, output

    def test_legacy_obj_fbx_arguments(self):
        result, _, output = self.run_main(".obj", ".obj", fbx=True)
        self.assertTrue(output.exists())
        self.assertTrue(Path(result["fbx_output"]).exists())
        self.assertIn("normals", self.calls)
        self.assertEqual(result["format"], "obj")

    def test_glb_stays_glb_and_preserves_resources(self):
        result, source, output = self.run_main(".glb", ".glb")
        self.assertEqual(output.name, "chair.v2.glb")
        self.assertEqual(result["material_count"], 1)
        self.assertEqual(result["texture_count"], 1)
        self.assertNotIn("normals", self.calls)
        options = next(k for tag, k in self.calls if tag == "export_glb")
        self.assertTrue(options["use_selection"])
        self.assertTrue(options["export_yup"])
        self.assertFalse(options["export_animations"])
        self.assertEqual(options["export_materials"], "EXPORT")
        self.assertTrue(source.exists())

    def test_target_height_and_base(self):
        result = self.module.normalize_meshes(self.objects, 1.8)
        self.assertAlmostEqual(result["final_height_m"], 1.8)
        self.assertAlmostEqual(result["base_z"], 0)
        self.assertAlmostEqual(result["scale_factor"], 0.9)

    def test_transformed_parents_are_baked_before_normalization(self):
        mesh = Mesh([(0, 0, 0), (1, 2, 3)])
        obj = Object(mesh, Matrix.Translation(Vector((12, -7, 9))) @ Matrix.Scale(2, 4), parent=object())
        result = self.module.normalize_meshes([obj], 1.5, preserve_normals=True)
        self.assertIsNone(obj.parent)
        self.assertAlmostEqual(result["original_height"], 6)
        self.assertAlmostEqual(result["final_height_m"], 1.5)
        self.assertAlmostEqual(result["base_z"], 0)
        self.assertEqual(obj.matrix_world.rows, Matrix.Identity(4).rows)

    def test_multiple_meshes_keep_relative_positions(self):
        first = Object(Mesh([(0, 0, 0), (1, 1, 1)]))
        second = Object(Mesh([(0, 0, 0), (1, 1, 1)]), Matrix.Translation(Vector((4, 0, 3))))
        result = self.module.normalize_meshes([first, second], 2, preserve_normals=True)
        self.assertAlmostEqual(result["original_height"], 4)
        self.assertAlmostEqual(result["final_height_m"], 2)
        self.assertAlmostEqual(second.data.vertices[0].z - first.data.vertices[0].z, 1.5)

    def test_shared_mesh_data_is_not_double_transformed(self):
        shared = Mesh([(0, 0, 0), (1, 1, 1)], users=2)
        first = Object(shared)
        second = Object(shared, Matrix.Translation(Vector((3, 0, 2))))
        self.module.normalize_meshes([first, second], 3, preserve_normals=True)
        self.assertIsNot(first.data, second.data)
        self.assertAlmostEqual(second.data.vertices[0].z - first.data.vertices[0].z, 2)

    def test_uv_material_identifiers_untouched(self):
        uv, mat = self.objects[0].data.uv_marker, self.objects[0].data.material_marker
        self.module.normalize_meshes(self.objects, 2, preserve_normals=True)
        self.assertIs(self.objects[0].data.uv_marker, uv)
        self.assertIs(self.objects[0].data.material_marker, mat)

    def test_zero_height_rejected(self):
        obj = Object(Mesh([(0, 0, 0), (1, 1, 0)]))
        with self.assertRaisesRegex(RuntimeError, "height"):
            self.module.normalize_meshes([obj], 1)

    def test_nonfinite_target_rejected(self):
        for height in [0, -1, float("nan"), float("inf")]:
            with self.subTest(height=height), self.assertRaises(ValueError):
                self.module.normalize_meshes(self.objects, height)

    def test_glb_envelope_invalid(self):
        for content in [b"", b"not a valid glb", struct.pack("<4sII", b"glTF", 1, 12)]:
            path = self.directory / "bad.glb"
            path.write_bytes(content)
            with self.subTest(content=content), self.assertRaises(ValueError):
                self.module.read_glb_json(path)

    def test_external_texture_rejected(self):
        path = self.directory / "external.glb"
        path.write_bytes(glb_bytes({"meshes": [{}], "images": [{"uri": "texture.png"}]}))
        with self.assertRaisesRegex(RuntimeError, "external"):
            self.module.validate_glb_output(path)

    def test_lost_materials_rejected(self):
        path = self.directory / "missing.glb"
        path.write_bytes(glb_bytes({"meshes": [{}]}))
        with self.assertRaisesRegex(RuntimeError, "materials"):
            self.module.validate_glb_output(path, {"materials": [{}]})

    def test_lost_textures_rejected(self):
        path = self.directory / "missing.glb"
        path.write_bytes(glb_bytes({"meshes": [{}], "materials": [{}]}))
        with self.assertRaisesRegex(RuntimeError, "textures"):
            self.module.validate_glb_output(path, {"materials": [{}], "textures": [{}]})

    def test_no_mesh_rejected(self):
        path = self.directory / "missing.glb"
        path.write_bytes(glb_bytes({"materials": [{}]}))
        with self.assertRaisesRegex(RuntimeError, "no mesh"):
            self.module.validate_glb_output(path)

    def test_parse_glb_output_without_fbx(self):
        args = self.module.parse_args(["--input", "a.glb", "--output", "out.glb", "--target-height", "2"])
        self.assertIsNone(args.fbx_output)

    def test_parse_cannot_overwrite_input(self):
        with self.assertRaisesRegex(ValueError, "distinct"):
            self.module.parse_args(["--input", "a.glb", "--output", "a.glb", "--target-height", "2"])

    def test_parse_glb_to_obj_rejected(self):
        with self.assertRaisesRegex(ValueError, "remain GLB"):
            self.module.parse_args(["--input", "a.glb", "--output", "a.obj", "--target-height", "2"])

    def test_parse_glb_to_fbx_rejected(self):
        with self.assertRaisesRegex(ValueError, "remain GLB"):
            self.module.parse_args(["--input", "a.glb", "--output", "out.glb", "--fbx-output", "out.fbx", "--target-height", "2"])

    def test_empty_output_rejected(self):
        p = self.directory / "empty.glb"
        p.touch()
        with self.assertRaisesRegex(RuntimeError, "non-empty"):
            self.module.ensure_output(p)


if __name__ == "__main__":
    unittest.main()

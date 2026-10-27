const std = @import("std");

// Funciones para leer y escribir archivos.
const File = opaque {};

extern "c" fn fopen(
    filename: [*:0]const u8,
    mode: [*:0]const u8,
) ?*File;

extern "c" fn fclose(file: *File) c_int;

extern "c" fn fgets(
    buffer: [*]u8,
    size: c_int,
    file: *File,
) ?[*:0]u8;

extern "c" fn fwrite(
    data: [*]const u8,
    size: usize,
    count: usize,
    file: *File,
) usize;

const WIDTH = 900;
const HEIGHT = 900;
const MAX_VERTICES = 100_000;

// Fondo negro. Cada pixel tiene tres componentes de color.
var pixels: [WIDTH * HEIGHT * 3]u8 =
    [_]u8{0} ** (WIDTH * HEIGHT * 3);

const Vec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

const Point = struct {
    x: i32,
    y: i32,
};

var vertices: [MAX_VERTICES]Vec3 = undefined;
var vertex_count: usize = 0;

// Angulos en radianes. Cero muestra el mono de frente.
const ANGLE_Y: f32 = 0.0;
const ANGLE_X: f32 = 0.0;

fn rotate(v: Vec3) Vec3 {
    const x = v.x * @cos(ANGLE_Y) + v.z * @sin(ANGLE_Y);
    const z = -v.x * @sin(ANGLE_Y) + v.z * @cos(ANGLE_Y);

    return .{
        .x = x,
        .y = v.y * @cos(ANGLE_X) - z * @sin(ANGLE_X),
        .z = v.y * @sin(ANGLE_X) + z * @cos(ANGLE_X),
    };
}

fn putPixel(x: i32, y: i32) void {
    if (x < 0 or x >= WIDTH or y < 0 or y >= HEIGHT) {
        return;
    }

    // Los BMP guardan las filas desde abajo hacia arriba.
    const column: usize = @intCast(x);
    const row: usize = @intCast(HEIGHT - 1 - y);
    const offset = (row * WIDTH + column) * 3;

    // Color blanco.
    pixels[offset] = 255;
    pixels[offset + 1] = 255;
    pixels[offset + 2] = 255;
}

// Dibuja una linea utilizando el algoritmo de Bresenham.
fn drawLine(a: Point, b: Point) void {
    var x = a.x;
    var y = a.y;

    const dx: i32 = @intCast(@abs(b.x - a.x));
    const dy: i32 = -@as(i32, @intCast(@abs(b.y - a.y)));

    const sx: i32 = if (a.x < b.x) 1 else -1;
    const sy: i32 = if (a.y < b.y) 1 else -1;

    var err = dx + dy;

    while (true) {
        putPixel(x, y);

        if (x == b.x and y == b.y) break;

        const twice = 2 * err;

        if (twice >= dy) {
            err += dy;
            x += sx;
        }

        if (twice <= dx) {
            err += dx;
            y += sy;
        }
    }
}

// Proyeccion ortografica: convertir coordenadas 3D a 2D.
fn project(v: Vec3, center: Vec3, scale: f32) Point {
    return .{
        .x = @intFromFloat(
            (v.x - center.x) * scale + WIDTH / 2.0,
        ),
        .y = @intFromFloat(
            HEIGHT / 2.0 - (v.y - center.y) * scale,
        ),
    };
}

// Extrae el indice del vertice de formatos como:
// 3, 3/1 o 3/1/2.
// Este cargador usa indices positivos, como los de Monito.obj.
fn parseIndex(token: []const u8) !usize {
    var parts = std.mem.splitScalar(u8, token, '/');

    const index = try std.fmt.parseInt(
        usize,
        parts.next() orelse return error.InvalidFace,
        10,
    );

    if (index == 0 or index > vertex_count) {
        return error.InvalidVertexIndex;
    }

    // OBJ comienza en 1; los arreglos comienzan en 0.
    return index - 1;
}

// Escribe un entero de 32 bits en formato little-endian.
fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}

fn saveBMP() !void {
    var header = [_]u8{0} ** 54;

    header[0] = 'B';
    header[1] = 'M';

    writeU32(&header, 2, 54 + pixels.len);
    writeU32(&header, 10, 54);
    writeU32(&header, 14, 40);
    writeU32(&header, 18, WIDTH);
    writeU32(&header, 22, HEIGHT);

    header[26] = 1;
    header[28] = 24;

    writeU32(&header, 34, pixels.len);

    // Con un ancho de 900, cada fila ocupa 2700 bytes,
    // divisible entre 4: no necesita bytes de relleno.
    const file = fopen("resultado.bmp", "wb") orelse
        return error.CannotCreateImage;
    defer _ = fclose(file);

    if (fwrite(&header, 1, header.len, file) != header.len) {
        return error.WriteFailed;
    }

    if (fwrite(&pixels, 1, pixels.len, file) != pixels.len) {
        return error.WriteFailed;
    }
}

pub fn main() !void {
    // Primera lectura: cargar los vertices.
    const input = fopen("Monito.obj", "r") orelse {
        std.debug.print(
            "No se encontro Monito.obj. Colocalo junto a main.zig y ejecuta desde esa carpeta.\n",
            .{},
        );
        return error.ModelNotFound;
    };

    var buffer: [8192]u8 = undefined;

    {
        defer _ = fclose(input);

        while (fgets(&buffer, @intCast(buffer.len), input)) |raw| {
            const line = std.mem.span(raw);
            var tokens = std.mem.tokenizeAny(u8, line, " \t\r\n");

            const kind = tokens.next() orelse continue;

            if (!std.mem.eql(u8, kind, "v")) continue;

            if (vertex_count >= MAX_VERTICES) {
                return error.TooManyVertices;
            }

            const x = try std.fmt.parseFloat(
                f32,
                tokens.next() orelse return error.InvalidVertex,
            );

            const y = try std.fmt.parseFloat(
                f32,
                tokens.next() orelse return error.InvalidVertex,
            );

            const z = try std.fmt.parseFloat(
                f32,
                tokens.next() orelse return error.InvalidVertex,
            );

            if (!std.math.isFinite(x) or
                !std.math.isFinite(y) or
                !std.math.isFinite(z))
            {
                return error.InvalidVertex;
            }

            vertices[vertex_count] = rotate(.{
                .x = x,
                .y = y,
                .z = z,
            });

            vertex_count += 1;
        }
    }

    if (vertex_count == 0) return error.EmptyModel;

    // Calcular limites del modelo para centrarlo.
    var min = vertices[0];
    var max = vertices[0];

    for (vertices[0..vertex_count]) |v| {
        min.x = @min(min.x, v.x);
        min.y = @min(min.y, v.y);

        max.x = @max(max.x, v.x);
        max.y = @max(max.y, v.y);
    }

    const center = Vec3{
        .x = (min.x + max.x) / 2.0,
        .y = (min.y + max.y) / 2.0,
        .z = 0,
    };

    const extent = @max(max.x - min.x, max.y - min.y);

    if (extent <= 0) return error.DegenerateModel;

    // Dejar un margen alrededor del modelo.
    const scale: f32 = 740.0 / extent;

    // Segunda lectura: cargar las caras y dibujar sus aristas.
    const faces = fopen("Monito.obj", "r") orelse
        return error.ModelNotFound;
    defer _ = fclose(faces);

    var face_count: usize = 0;

    while (fgets(&buffer, @intCast(buffer.len), faces)) |raw| {
        const line = std.mem.span(raw);
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r\n");

        const kind = tokens.next() orelse continue;

        if (!std.mem.eql(u8, kind, "f")) continue;

        const first = try parseIndex(
            tokens.next() orelse return error.InvalidFace,
        );

        var previous = first;
        var count: usize = 1;

        while (tokens.next()) |token| {
            if (token[0] == '#') break;

            const current = try parseIndex(token);

            drawLine(
                project(vertices[previous], center, scale),
                project(vertices[current], center, scale),
            );

            previous = current;
            count += 1;
        }

        if (count < 3) return error.InvalidFace;

        // Cerrar la cara uniendo el ultimo vertice con el primero.
        drawLine(
            project(vertices[previous], center, scale),
            project(vertices[first], center, scale),
        );

        face_count += 1;
    }

    if (face_count == 0) return error.NoFaces;

    try saveBMP();

    std.debug.print(
        "Modelo cargado: {d} vertices y {d} caras.\nImagen creada: resultado.bmp\n",
        .{ vertex_count, face_count },
    );
}
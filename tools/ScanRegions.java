import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;

// Replicates vanilla MC 1.7.10 chunk loading byte-for-byte:
//   RegionFile.getChunkDataInputStream -> CompressedStreamTools.func_74794_a
//   -> AnvilChunkLoader.checkedReadChunkFromNBT (requires Level + Level.Sections)
// Uses the real java.io.DataInputStream (strict readUTF / readFully) and
// InflaterInputStream, so anything this flags is exactly what the game rejects.
// A rejected chunk makes ChunkProviderServer.provideChunk return null on first
// touch (Forge 1.7.10 loadChunk quirk) -> NPE in WorldServer tick -> crash, and
// the chunk is regenerated as fresh terrain when the crashing server saves.
//
// Usage:
//   java ScanRegions [<worldRoot>]          scan every <root>/**/region/*.mca
//   java ScanRegions files  < paths.txt     scan the listed .mca files
//   java ScanRegions check  < "path idx"    check single chunks (used by repair_chunks.py)
// Output: BAD/SKIP lines + "--- files=N chunks=N BAD=N SKIP=N" summary.
public class ScanRegions {

    static final long MAX_ARRAY = 64L * 1024 * 1024;

    static final class Ctx { Set<String> root = new HashSet<>(); Set<String> level = new HashSet<>(); }

    static void readTag(DataInputStream in, int type) throws IOException { readTag(in, type, -1, "", new Ctx()); }

    static void readTag(DataInputStream in, int type, int depth, String parent, Ctx ctx) throws IOException {
        switch (type) {
            case 0: return;
            case 1: in.readByte(); return;
            case 2: in.readShort(); return;
            case 3: in.readInt(); return;
            case 4: in.readLong(); return;
            case 5: in.readFloat(); return;
            case 6: in.readDouble(); return;
            case 7: {
                int len = in.readInt();
                if (len < 0 || len > MAX_ARRAY) throw new IOException("insane byte-array length " + len);
                in.readFully(new byte[len]);
                return;
            }
            case 8: in.readUTF(); return;
            case 9: {
                byte t = in.readByte();
                int len = in.readInt();
                if (t == 0 && len > 0) throw new IOException("Missing type on ListTag");
                if (len < 0) throw new IOException("negative list length " + len);
                for (int i = 0; i < len; i++) readTag(in, t, depth + 1, "", ctx);
                return;
            }
            case 10: {
                byte t;
                while ((t = in.readByte()) != 0) {
                    String name = in.readUTF();
                    if (depth == 0) ctx.root.add(name);
                    else if (depth == 1 && parent.equals("Level")) ctx.level.add(name);
                    readTag(in, t, depth + 1, name, ctx);
                }
                return;
            }
            case 11: {
                int len = in.readInt();
                if (len < 0 || len > MAX_ARRAY / 4) throw new IOException("insane int-array length " + len);
                for (int i = 0; i < len; i++) in.readInt();
                return;
            }
            default: throw new IOException("Invalid tag id: " + type);
        }
    }

    // returns null if OK, else the error string. "SKIP:" prefix = game would
    // silently regenerate (RegionFile returns null), not crash.
    static String checkChunk(byte[] region, int idx) {
        int he = idx * 4;
        if (region.length < 8192) return "SKIP:region shorter than header";
        int offset = ((region[he] & 0xFF) << 16) | ((region[he+1] & 0xFF) << 8) | (region[he+2] & 0xFF);
        int numSectors = region[he+3] & 0xFF;
        if (offset == 0) return null;                       // chunk absent
        int totalSectors = region.length / 4096;
        if (offset + numSectors > totalSectors) return "SKIP:sector range past EOF";
        int start = offset * 4096;
        if (start + 5 > region.length) return "SKIP:start past EOF";
        int length = ((region[start] & 0xFF) << 24) | ((region[start+1] & 0xFF) << 16)
                   | ((region[start+2] & 0xFF) << 8) | (region[start+3] & 0xFF);
        if (length <= 0 || length > 4096 * numSectors) return "SKIP:invalid chunk length " + length;
        int ver = region[start+4] & 0xFF;
        if (ver != 1 && ver != 2) return "SKIP:unknown compression " + ver;
        try {
            InputStream base = new ByteArrayInputStream(region, start + 5, length - 1);
            InputStream dec = (ver == 1) ? new GZIPInputStream(base) : new InflaterInputStream(base);
            DataInputStream in = new DataInputStream(new BufferedInputStream(dec));
            byte rootType = in.readByte();
            if (rootType != 10) return "TypeError: non-Compound root tag id " + rootType;
            in.readUTF();
            Ctx ctx = new Ctx();
            readTag(in, 10, 0, "", ctx);
            if (!ctx.root.contains("Level")) return "NOLEVEL: root keys=" + ctx.root;
            if (!ctx.level.contains("Sections")) return "NOSECTIONS: level keys=" + ctx.level;
            return null;
        } catch (Throwable t) {
            String m = t.getMessage();
            return t.getClass().getName() + (m == null ? "" : ": " + m);
        }
    }

    public static void main(String[] args) throws Exception {
        if (args.length > 0 && args[0].equals("check")) {
            // stdin: "<mcaPath> <chunkIndex>" per line
            BufferedReader br = new BufferedReader(new InputStreamReader(System.in));
            Map<String, byte[]> cache = new HashMap<>();
            String line;
            while ((line = br.readLine()) != null) {
                if (line.isBlank()) continue;
                int sp = line.lastIndexOf(" ");
                String p = line.substring(0, sp);
                int idx = Integer.parseInt(line.substring(sp + 1).trim());
                byte[] data = cache.computeIfAbsent(p, k -> {
                    try { return Files.readAllBytes(Paths.get(k)); } catch (Exception e) { return null; }
                });
                if (data == null) { System.out.println(line + "\tMISSING"); continue; }
                String err = checkChunk(data, idx);
                System.out.println(line + "\t" + (err == null ? "OK" : err));
            }
            return;
        }
        List<Path> mcas = new ArrayList<>();
        if (args.length > 0 && args[0].equals("files")) {
            // stdin: one .mca path per line (used by 'gtnh backup' to validate the staged region files)
            BufferedReader br = new BufferedReader(new InputStreamReader(System.in));
            String line;
            while ((line = br.readLine()) != null) {
                if (line.isBlank()) continue;
                Path p = Paths.get(line.trim());
                if (Files.isRegularFile(p) && line.endsWith(".mca")) mcas.add(p);
            }
        } else {
            String root = args.length > 0 ? args[0] : "World";
            Files.walk(Paths.get(root))
                 .filter(p -> p.toString().endsWith(".mca") && p.getParent().getFileName().toString().equals("region"))
                 .sorted().forEach(mcas::add);
        }
        long scanned = 0; int bad = 0, skip = 0;
        for (Path p : mcas) {
            byte[] data = Files.readAllBytes(p);
            String fn = p.getFileName().toString();
            String[] parts = fn.split("\\.");
            int rx = Integer.parseInt(parts[1]), rz = Integer.parseInt(parts[2]);
            for (int idx = 0; idx < 1024; idx++) {
                int he = idx * 4;
                if (data.length < 8192) break;
                int off = ((data[he]&0xFF)<<16)|((data[he+1]&0xFF)<<8)|(data[he+2]&0xFF);
                if (off == 0) continue;
                scanned++;
                String err = checkChunk(data, idx);
                if (err != null) {
                    int cx = rx * 32 + (idx % 32), cz = rz * 32 + (idx / 32);
                    if (err.startsWith("SKIP:")) { skip++; System.out.println("SKIP\t" + p + "\t" + idx + "\t(" + cx + "," + cz + ")\t" + err.substring(5)); }
                    else { bad++; System.out.println("BAD\t" + p + "\t" + idx + "\t(" + cx + "," + cz + ")\t" + err); }
                }
            }
        }
        System.out.println("--- files=" + mcas.size() + " chunks=" + scanned + " BAD=" + bad + " SKIP=" + skip);
    }
}

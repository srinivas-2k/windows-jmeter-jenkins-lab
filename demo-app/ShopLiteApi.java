/*
 * ShopLite API - a tiny system-under-test for the Windows Jenkins + JMeter course.
 *
 * Why this exists: we must only load-test endpoints we own. This file IS that endpoint.
 * It needs nothing but Java 21 (the same JDK JMeter uses) - no Maven, no Gradle, no build.
 *
 *   Run (CMD or PowerShell):  java demo-app\ShopLiteApi.java
 *   Custom port:              java demo-app\ShopLiteApi.java --port 8081
 *   Start slow / failing:     java demo-app\ShopLiteApi.java --delay-ms 300 --error-pct 5
 *
 * Endpoints
 *   GET  /health                       -> {"status":"UP",...}
 *   GET  /api/products                 -> product list
 *   GET  /api/products/{id}            -> one product, 404 if unknown
 *   GET  /api/search?q=text            -> products whose name contains text
 *   POST /api/login                    -> {"token":"..."}  body: {"username":"user01","password":"Passw0rd!"}
 *   POST /api/orders   (Bearer token)  -> 201 {"orderId":"..."} body: {"productId":1,"quantity":2}
 *   GET  /api/orders/{id} (Bearer)     -> the order, 404 if unknown
 *   GET  /admin/chaos                  -> current fault-injection settings
 *   POST /admin/chaos?delayMs=500&errorPct=10   -> change them live (used to demo quality gates)
 *   POST /admin/reset                  -> clear orders/tokens and chaos settings
 *
 * Chaos settings apply to /api/* only, never to /health, so a "slow" server still looks alive.
 */

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadLocalRandom;
import java.util.concurrent.atomic.AtomicLong;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class ShopLiteApi {

    record Product(int id, String name, String category, double price) {}

    static final List<Product> PRODUCTS = List.of(
            new Product(1, "Wireless Mouse", "accessories", 19.99),
            new Product(2, "Mechanical Keyboard", "accessories", 79.50),
            new Product(3, "27 inch Monitor", "displays", 229.00),
            new Product(4, "USB-C Dock", "accessories", 119.00),
            new Product(5, "Noise Cancelling Headset", "audio", 149.99),
            new Product(6, "Webcam HD", "video", 59.90),
            new Product(7, "Laptop Stand", "accessories", 34.00),
            new Product(8, "Portable SSD 1TB", "storage", 99.00),
            new Product(9, "Desk Microphone", "audio", 89.00),
            new Product(10, "Ergonomic Chair", "furniture", 349.00));

    static final String VALID_PASSWORD = "Passw0rd!";
    static final Map<String, String> TOKENS = new ConcurrentHashMap<>();   // token -> username
    static final Map<String, String> ORDERS = new ConcurrentHashMap<>();   // orderId -> json
    static final AtomicLong REQUESTS = new AtomicLong();
    static final Instant STARTED = Instant.now();

    static volatile int delayMs = 0;
    static volatile int errorPct = 0;

    public static void main(String[] args) throws IOException {
        int port = 8081;
        String bind = "0.0.0.0";
        for (int i = 0; i < args.length - 1; i++) {
            switch (args[i]) {
                case "--port" -> port = Integer.parseInt(args[i + 1]);
                case "--bind" -> bind = args[i + 1];
                case "--delay-ms" -> delayMs = Integer.parseInt(args[i + 1]);
                case "--error-pct" -> errorPct = Integer.parseInt(args[i + 1]);
                default -> { }
            }
        }

        HttpServer server = HttpServer.create(new InetSocketAddress(bind, port), 200);
        // One virtual thread per request (Java 21): cheap, so the SUT is never the bottleneck in class.
        server.setExecutor(Executors.newVirtualThreadPerTaskExecutor());
        server.createContext("/", ShopLiteApi::route);
        server.start();

        System.out.printf("ShopLite API listening on http://%s:%d  (delayMs=%d, errorPct=%d)%n",
                bind, port, delayMs, errorPct);
        System.out.println("Try: http://localhost:" + port + "/health   Press Ctrl+C to stop.");
    }

    static void route(HttpExchange ex) throws IOException {
        REQUESTS.incrementAndGet();
        String method = ex.getRequestMethod();
        String path = ex.getRequestURI().getPath();
        try {
            if (path.equals("/health")) {
                send(ex, 200, "{\"status\":\"UP\",\"uptimeSeconds\":"
                        + (Instant.now().getEpochSecond() - STARTED.getEpochSecond())
                        + ",\"requests\":" + REQUESTS.get() + "}");
                return;
            }
            if (path.startsWith("/admin/")) {
                admin(ex, method, path);
                return;
            }
            if (path.startsWith("/api/")) {
                if (applyChaos(ex)) return;
                api(ex, method, path);
                return;
            }
            send(ex, 404, "{\"error\":\"not found\",\"path\":\"" + esc(path) + "\"}");
        } catch (Exception e) {
            send(ex, 500, "{\"error\":\"" + esc(String.valueOf(e.getMessage())) + "\"}");
        }
    }

    /** Returns true if chaos already answered the request with an injected error. */
    static boolean applyChaos(HttpExchange ex) throws IOException {
        int d = delayMs;
        if (d > 0) {
            // +/-20% jitter so percentiles look like a real system, not a flat line
            int jitter = d / 5;
            sleep(d + (jitter > 0 ? ThreadLocalRandom.current().nextInt(-jitter, jitter + 1) : 0));
        }
        if (errorPct > 0 && ThreadLocalRandom.current().nextInt(100) < errorPct) {
            send(ex, 503, "{\"error\":\"injected failure (chaos errorPct=" + errorPct + ")\"}");
            return true;
        }
        return false;
    }

    static void api(HttpExchange ex, String method, String path) throws IOException {
        // small natural latency (5-25 ms) so dashboards are not all zeros
        sleep(5 + ThreadLocalRandom.current().nextInt(21));

        if (method.equals("GET") && path.equals("/api/products")) {
            StringBuilder sb = new StringBuilder("{\"count\":" + PRODUCTS.size() + ",\"products\":[");
            for (int i = 0; i < PRODUCTS.size(); i++) {
                if (i > 0) sb.append(',');
                sb.append(json(PRODUCTS.get(i)));
            }
            send(ex, 200, sb.append("]}").toString());
            return;
        }
        if (method.equals("GET") && path.startsWith("/api/products/")) {
            int id = parseIntOr(path.substring("/api/products/".length()), -1);
            for (Product p : PRODUCTS) {
                if (p.id() == id) { send(ex, 200, json(p)); return; }
            }
            send(ex, 404, "{\"error\":\"product not found\",\"id\":\"" + esc(path.substring(14)) + "\"}");
            return;
        }
        if (method.equals("GET") && path.equals("/api/search")) {
            String q = query(ex, "q").toLowerCase();
            List<String> hits = new ArrayList<>();
            for (Product p : PRODUCTS) {
                if (p.name().toLowerCase().contains(q) || p.category().equals(q)) hits.add(json(p));
            }
            send(ex, 200, "{\"query\":\"" + esc(q) + "\",\"count\":" + hits.size()
                    + ",\"products\":[" + String.join(",", hits) + "]}");
            return;
        }
        if (method.equals("POST") && path.equals("/api/login")) {
            String body = body(ex);
            String user = field(body, "username");
            String pass = field(body, "password");
            if (user == null || !user.matches("user\\d{2}") || !VALID_PASSWORD.equals(pass)) {
                send(ex, 401, "{\"error\":\"invalid credentials\"}");
                return;
            }
            String token = UUID.randomUUID().toString().replace("-", "");
            TOKENS.put(token, user);
            send(ex, 200, "{\"username\":\"" + user + "\",\"token\":\"" + token + "\"}");
            return;
        }
        if (path.equals("/api/orders") || path.startsWith("/api/orders/")) {
            String user = authUser(ex);
            if (user == null) {
                send(ex, 401, "{\"error\":\"missing or invalid bearer token\"}");
                return;
            }
            if (method.equals("POST") && path.equals("/api/orders")) {
                String body = body(ex);
                int productId = parseIntOr(field(body, "productId"), -1);
                int qty = parseIntOr(field(body, "quantity"), 1);
                if (PRODUCTS.stream().noneMatch(p -> p.id() == productId) || qty < 1) {
                    send(ex, 400, "{\"error\":\"invalid productId or quantity\"}");
                    return;
                }
                String orderId = "ORD-" + UUID.randomUUID().toString().substring(0, 8).toUpperCase();
                String order = "{\"orderId\":\"" + orderId + "\",\"username\":\"" + user
                        + "\",\"productId\":" + productId + ",\"quantity\":" + qty
                        + ",\"status\":\"CREATED\"}";
                ORDERS.put(orderId, order);
                send(ex, 201, order);
                return;
            }
            if (method.equals("GET") && path.startsWith("/api/orders/")) {
                String order = ORDERS.get(path.substring("/api/orders/".length()));
                if (order == null) send(ex, 404, "{\"error\":\"order not found\"}");
                else send(ex, 200, order);
                return;
            }
        }
        send(ex, 404, "{\"error\":\"no route\",\"method\":\"" + method + "\",\"path\":\"" + esc(path) + "\"}");
    }

    static void admin(HttpExchange ex, String method, String path) throws IOException {
        if (path.equals("/admin/chaos") && method.equals("POST")) {
            String d = query(ex, "delayMs");
            String e = query(ex, "errorPct");
            if (!d.isEmpty()) delayMs = Math.max(0, parseIntOr(d, 0));
            if (!e.isEmpty()) errorPct = Math.min(100, Math.max(0, parseIntOr(e, 0)));
            System.out.printf("[admin] chaos changed: delayMs=%d errorPct=%d%n", delayMs, errorPct);
        } else if (path.equals("/admin/reset") && method.equals("POST")) {
            delayMs = 0;
            errorPct = 0;
            TOKENS.clear();
            ORDERS.clear();
            System.out.println("[admin] reset");
        } else if (!(path.equals("/admin/chaos") && method.equals("GET"))) {
            send(ex, 404, "{\"error\":\"no admin route\"}");
            return;
        }
        send(ex, 200, "{\"delayMs\":" + delayMs + ",\"errorPct\":" + errorPct
                + ",\"activeTokens\":" + TOKENS.size() + ",\"orders\":" + ORDERS.size() + "}");
    }

    // ---------------------------------------------------------------- helpers

    static String authUser(HttpExchange ex) {
        String h = ex.getRequestHeaders().getFirst("Authorization");
        if (h == null || !h.startsWith("Bearer ")) return null;
        return TOKENS.get(h.substring(7).trim());
    }

    static String json(Product p) {
        return String.format(java.util.Locale.ROOT,
                "{\"id\":%d,\"name\":\"%s\",\"category\":\"%s\",\"price\":%.2f}",
                p.id(), p.name(), p.category(), p.price());
    }

    static String body(HttpExchange ex) throws IOException {
        try (InputStream in = ex.getRequestBody()) {
            return new String(in.readAllBytes(), StandardCharsets.UTF_8);
        }
    }

    /** Minimal JSON field reader - good enough for flat request bodies, keeps this file dependency-free. */
    static String field(String json, String name) {
        Matcher m = Pattern.compile("\"" + Pattern.quote(name) + "\"\\s*:\\s*(\"([^\"]*)\"|(-?\\d+))").matcher(json);
        if (!m.find()) return null;
        return m.group(2) != null ? m.group(2) : m.group(3);
    }

    static String query(HttpExchange ex, String name) {
        String raw = ex.getRequestURI().getRawQuery();
        if (raw == null) return "";
        for (String pair : raw.split("&")) {
            int i = pair.indexOf('=');
            String k = i < 0 ? pair : pair.substring(0, i);
            if (k.equals(name)) {
                return i < 0 ? "" : URLDecoder.decode(pair.substring(i + 1), StandardCharsets.UTF_8);
            }
        }
        return "";
    }

    static int parseIntOr(String s, int fallback) {
        try { return Integer.parseInt(s.trim()); } catch (Exception e) { return fallback; }
    }

    static String esc(String s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"");
    }

    static void sleep(int ms) {
        try { Thread.sleep(Math.max(0, ms)); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
    }

    static void send(HttpExchange ex, int status, String json) throws IOException {
        byte[] bytes = json.getBytes(StandardCharsets.UTF_8);
        ex.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
        ex.getResponseHeaders().set("X-Served-By", "ShopLiteApi");
        ex.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(bytes);
        }
    }
}

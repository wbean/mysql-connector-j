import java.sql.*;

public class DdbTest {
    public static void main(String[] args) throws Exception {
        String url = "jdbc:mysql://10.59.187.166:6000/lofter_ddb_test_gz"
                + "?connectTimeout=5000&socketTimeout=30000&characterEncoding=utf-8";

        // Credentials: set via environment variables DB_USER and DB_PASSWORD
        String dbUser = System.getenv("DB_USER");
        String dbPassword = System.getenv("DB_PASSWORD");
        Connection conn = DriverManager.getConnection(url, dbUser, dbPassword);
        DatabaseMetaData dbmd = conn.getMetaData();

        System.out.println("=== getImportedKeys (triggers extractForeignKeyFromCreateTable) ===");
        try {
            ResultSet rs = dbmd.getImportedKeys(null, null, "C2C_ClearCommand");
            int count = 0;
            while (rs.next()) count++;
            rs.close();
            System.out.println("OK, FK count: " + count);
        } catch (Exception e) {
            System.out.println("ERROR: " + e.getMessage());
        }

        System.out.println("\n=== getCatalogName from query result ===");
        Statement st = conn.createStatement();
        ResultSet rs2 = st.executeQuery("SELECT id, sn, ext FROM C2C_ClearCommand LIMIT 1");
        System.out.println("catalog=" + rs2.getMetaData().getCatalogName(1));
        rs2.close(); st.close();

        conn.close();
        System.out.println("Done.");
    }
}

import SQLKit
import SQLKitBenchmark
import XCTest

final class SQLKitTests: XCTestCase {
    func testBenchmarker() throws {
        let db = TestDatabase()
        let benchmarker = SQLBenchmarker(on: db)
        try benchmarker.run()
    }
    
    func testLockingClause_forUpdate() throws {
        let db = TestDatabase()
        try db.select().column("*")
            .from("planets")
            .where("name", .equal, "Earth")
            .for(.update)
            .run().wait()
        XCTAssertEqual(db.results[0], "SELECT * FROM `planets` WHERE `name` = ? FOR UPDATE")
    }
    
    func testLockingClause_lockInShareMode() throws {
        let db = TestDatabase()
        try db.select().column("*")
            .from("planets")
            .where("name", .equal, "Earth")
            .lockingClause(SQLRaw("LOCK IN SHARE MODE"))
            .run().wait()
        XCTAssertEqual(db.results[0], "SELECT * FROM `planets` WHERE `name` = ? LOCK IN SHARE MODE")
    }
    
    func testRawQueryStringInterpolation() throws {
        let db = TestDatabase()
        let (table, planet) = ("planets", "Earth")
        let builder = db.raw("SELECT * FROM \(table) WHERE name = \(bind: planet)")
        var serializer = SQLSerializer(database: db)
        builder.query.serialize(to: &serializer)

        XCTAssertEqual(serializer.sql, "SELECT * FROM planets WHERE name = ?")
        XCTAssert(serializer.binds.first! as! String == "Earth")
    }

    func testGroupByHaving() throws {
        let db = TestDatabase()
        try db.select().column("*")
            .from("planets")
            .groupBy("color")
            .having("color", .equal, "blue")
            .run().wait()
        XCTAssertEqual(db.results[0], "SELECT * FROM `planets` GROUP BY `color` HAVING `color` = ?")
    }

    func testIfExists() throws {
        let db = TestDatabase()

        try db.drop(table: "planets").ifExists().run().wait()
        XCTAssertEqual(db.results[0], "DROP TABLE IF EXISTS `planets`")

        db._dialect.supportsIfExists = false
        try db.drop(table: "planets").ifExists().run().wait()
        XCTAssertEqual(db.results[1], "DROP TABLE `planets`")
    }
    
    func testUpsertWithUpdate() throws {
        let db = TestDatabase()
        
        try db
            .upsert(into: "planets")
            .columns("id", "name", "galaxy_id", "type")
            .values(UUID(), "Earth", UUID(), "rocky")
            .onConflict(
                with: ["galaxy_id", "id"],
                where: { $0.where("galaxy_id", .notEqual, "special_galaxy_id") },
                do: {
                    $0.set("name", to: "another_planet")
                      .set(excludedValueOf: "type")
                      .where("type", .equal, "gas_giant")
                }
            )
            .run().wait()
        
        XCTAssertEqual(db.results[0], """
            INSERT INTO `planets` (`id`, `name`, `galaxy_id`, `type`) VALUES (?, ?, ?, ?) ON CONFLICT (`galaxy_id`, `id`) WHERE `galaxy_id` <> ? DO UPDATE  SET `name` = ?, `type` = `excluded`.`type` WHERE `type` = ?
            """)
    }
    
    func testUpsertUsingExcludedModel() throws {
        struct Foo: Codable {
            let id: UUID
            let foo: Int
            let bar: Double?
            let baz: String
        }

        let db = TestDatabase()
        let model = Foo(id: UUID(), foo: 1, bar: 4.2, baz: "gadkf")
        
        try! XCTUnwrap(db
            .upsert(into: "foos")
            .model(model)
            .onConflict(with: ["id"]) { try $0.set(excludedModel: model) }
            .run().wait()
        )
        
        XCTAssertEqual(db.results[0], "INSERT INTO `foos` (`id`, `foo`, `bar`, `baz`) VALUES (?, ?, ?, ?) ON CONFLICT (`id`) DO UPDATE  SET `id` = `excluded`.`id`, `foo` = `excluded`.`foo`, `bar` = `excluded`.`bar`, `baz` = `excluded`.`baz`")
    }
    
    func testUpsertWithIgnoreAction() throws {
        let db = TestDatabase()
        
        try! XCTUnwrap(db
            .upsert(into: "planets")
            .columns("id")
            .values(UUID())
            .ignoreConflict()
            .run().wait()
        )
        try! XCTUnwrap(db
            .upsert(into: "planets")
            .columns("id")
            .values(UUID())
            .ignoreConflict(with: ["id"], where: { $0.where(SQLColumn("id"), .equal, SQLBind(UUID())) })
            .run().wait()
        )
        
        XCTAssertEqual(db.results[0], "INSERT INTO `planets` (`id`) VALUES (?) ON CONFLICT DO NOTHING")
        XCTAssertEqual(db.results[1], "INSERT INTO `planets` (`id`) VALUES (?) ON CONFLICT (`id`) WHERE `id` = ? DO NOTHING")
    }
    
    func testUpsertWithoutConflictClause() throws {
        let db = TestDatabase()
        let id = UUID()
        
        try! XCTUnwrap(db.upsert(into: "planets").columns("id").values(id).run().wait())
        try! XCTUnwrap(db.insert(into: "planets").columns("id").values(id).run().wait())
        XCTAssertEqual(db.results[0], db.results[1])
        XCTAssertEqual(db.results[0], "INSERT INTO `planets` (`id`) VALUES (?)")
    }
}

// MARK: Table Creation

extension SQLKitTests {
    func testColumnConstraints() throws {
        let db = TestDatabase()

        try db.create(table: "planets")
            .column("id", type: .bigint, .primaryKey)
            .column("name", type: .text, .default("unnamed"))
            .column("galaxy_id", type: .bigint, .references("galaxies", "id"))
            .column("diameter", type: .int, .check(SQLRaw("diameter > 0")))
            .column("important", type: .text, .notNull)
            .column("special", type: .text, .unique)
            .column("automatic", type: .text, .generated(SQLRaw("CONCAT(name, special)")))
            .column("collated", type: .text, .collate(name: "default"))
            .run().wait()

        XCTAssertEqual(db.results[0],
"""
CREATE TABLE `planets`(`id` BIGINT PRIMARY KEY AUTOINCREMENT, `name` TEXT DEFAULT 'unnamed', `galaxy_id` BIGINT REFERENCES `galaxies` (`id`), `diameter` INTEGER CHECK (diameter > 0), `important` TEXT NOT NULL, `special` TEXT UNIQUE, `automatic` TEXT GENERATED ALWAYS AS (CONCAT(name, special)) STORED, `collated` TEXT COLLATE `default`)
"""
                       )
    }

    func testMultipleColumnConstraintsPerRow() throws {
        let db = TestDatabase()

        try db.create(table: "planets")
            .column("id", type: .bigint, .notNull, .primaryKey)
            .run().wait()

        XCTAssertEqual(db.results[0], "CREATE TABLE `planets`(`id` BIGINT NOT NULL PRIMARY KEY AUTOINCREMENT)")
    }

    func testPrimaryKeyColumnConstraintVariants() throws {
        let db = TestDatabase()

        try db.create(table: "planets1")
            .column("id", type: .bigint, .primaryKey)
            .run().wait()

        try db.create(table: "planets2")
            .column("id", type: .bigint, .primaryKey(autoIncrement: false))
            .run().wait()

        XCTAssertEqual(db.results[0], "CREATE TABLE `planets1`(`id` BIGINT PRIMARY KEY AUTOINCREMENT)")

        XCTAssertEqual(db.results[1], "CREATE TABLE `planets2`(`id` BIGINT PRIMARY KEY)")
    }

    func testDefaultColumnConstraintVariants() throws {
        let db = TestDatabase()

        try db.create(table: "planets1")
            .column("name", type: .text, .default("unnamed"))
            .run().wait()

        try db.create(table: "planets2")
            .column("diameter", type: .int, .default(10))
            .run().wait()

        try db.create(table: "planets3")
            .column("diameter", type: .real, .default(11.5))
            .run().wait()

        try db.create(table: "planets4")
            .column("current", type: .custom(SQLRaw("BOOLEAN")), .default(false))
            .run().wait()

        try db.create(table: "planets5")
            .column("current", type: .custom(SQLRaw("BOOLEAN")), .default(SQLLiteral.boolean(true)))
            .run().wait()

        XCTAssertEqual(db.results[0], "CREATE TABLE `planets1`(`name` TEXT DEFAULT 'unnamed')")

        XCTAssertEqual(db.results[1], "CREATE TABLE `planets2`(`diameter` INTEGER DEFAULT 10)")

        XCTAssertEqual(db.results[2], "CREATE TABLE `planets3`(`diameter` REAL DEFAULT 11.5)")

        XCTAssertEqual(db.results[3], "CREATE TABLE `planets4`(`current` BOOLEAN DEFAULT false)")

        XCTAssertEqual(db.results[4], "CREATE TABLE `planets5`(`current` BOOLEAN DEFAULT true)")
    }

    func testForeignKeyColumnConstraintVariants() throws {
        let db = TestDatabase()

        try db.create(table: "planets1")
            .column("galaxy_id", type: .bigint, .references("galaxies", "id"))
            .run().wait()

        try db.create(table: "planets2")
            .column("galaxy_id", type: .bigint, .references("galaxies", "id", onDelete: .cascade, onUpdate: .restrict))
            .run().wait()

        XCTAssertEqual(db.results[0], "CREATE TABLE `planets1`(`galaxy_id` BIGINT REFERENCES `galaxies` (`id`))")

        XCTAssertEqual(db.results[1], "CREATE TABLE `planets2`(`galaxy_id` BIGINT REFERENCES `galaxies` (`id`) ON DELETE CASCADE ON UPDATE RESTRICT)")
    }

    func testTableConstraints() throws {
        let db = TestDatabase()

        try db.create(table: "planets")
            .column("id", type: .bigint)
            .column("name", type: .text)
            .column("diameter", type: .int)
            .column("galaxy_name", type: .text)
            .column("galaxy_id", type: .bigint)
            .primaryKey("id")
            .unique("name")
            .check(SQLRaw("diameter > 0"), named: "non-zero-diameter")
            .foreignKey(
                ["galaxy_id", "galaxy_name"],
                references: "galaxies",
                ["id", "name"]
            ).run().wait()

        XCTAssertEqual(db.results[0],
"""
CREATE TABLE `planets`(`id` BIGINT, `name` TEXT, `diameter` INTEGER, `galaxy_name` TEXT, `galaxy_id` BIGINT, PRIMARY KEY (`id`), UNIQUE (`name`), CONSTRAINT `non-zero-diameter` CHECK (diameter > 0), FOREIGN KEY (`galaxy_id`, `galaxy_name`) REFERENCES `galaxies` (`id`, `name`))
"""
                       )
    }

    func testCompositePrimaryKeyTableConstraint() throws {
        let db = TestDatabase()

        try db.create(table: "planets1")
            .column("id1", type: .bigint)
            .column("id2", type: .bigint)
            .primaryKey("id1", "id2")
            .run().wait()

        XCTAssertEqual(db.results[0], "CREATE TABLE `planets1`(`id1` BIGINT, `id2` BIGINT, PRIMARY KEY (`id1`, `id2`))")
    }

    func testCompositeUniqueTableConstraint() throws {
        let db = TestDatabase()

        try db.create(table: "planets1")
            .column("id1", type: .bigint)
            .column("id2", type: .bigint)
            .unique("id1", "id2")
            .run().wait()

        XCTAssertEqual(db.results[0], "CREATE TABLE `planets1`(`id1` BIGINT, `id2` BIGINT, UNIQUE (`id1`, `id2`))")
    }

    func testPrimaryKeyTableConstraintVariants() throws {
        let db = TestDatabase()

        try db.create(table: "planets1")
            .column("galaxy_name", type: .text)
            .column("galaxy_id", type: .bigint)
            .foreignKey(
                ["galaxy_id", "galaxy_name"],
                references: "galaxies",
                ["id", "name"]
        ).run().wait()

        try db.create(table: "planets2")
            .column("galaxy_id", type: .bigint)
            .foreignKey(
                ["galaxy_id"],
                references: "galaxies",
                ["id"]
        ).run().wait()

        try db.create(table: "planets3")
            .column("galaxy_id", type: .bigint)
            .foreignKey(
                ["galaxy_id"],
                references: "galaxies",
                ["id"],
                onDelete: .restrict,
                onUpdate: .cascade
        ).run().wait()

        XCTAssertEqual(db.results[0], "CREATE TABLE `planets1`(`galaxy_name` TEXT, `galaxy_id` BIGINT, FOREIGN KEY (`galaxy_id`, `galaxy_name`) REFERENCES `galaxies` (`id`, `name`))")

        XCTAssertEqual(db.results[1], "CREATE TABLE `planets2`(`galaxy_id` BIGINT, FOREIGN KEY (`galaxy_id`) REFERENCES `galaxies` (`id`))")

        XCTAssertEqual(db.results[2], "CREATE TABLE `planets3`(`galaxy_id` BIGINT, FOREIGN KEY (`galaxy_id`) REFERENCES `galaxies` (`id`) ON DELETE RESTRICT ON UPDATE CASCADE)")
    }

    func testSQLRowDecoder() throws {
        struct Foo: Codable {
            let id: UUID
            let foo: Int
            let bar: Double?
            let baz: String
        }

        do {
            let row = TestRow(data: [
                "id": UUID(),
                "foo": 42,
                "bar": Double?.none as Any,
                "baz": "vapor"
            ])

            let foo = try row.decode(model: Foo.self)
            XCTAssertEqual(foo.foo, 42)
            XCTAssertEqual(foo.bar, nil)
            XCTAssertEqual(foo.baz, "vapor")
        }
        do {
            let row = TestRow(data: [
                "foos_id": UUID(),
                "foos_foo": 42,
                "foos_bar": Double?.none as Any,
                "foos_baz": "vapor"
            ])

            let foo = try row.decode(model: Foo.self, prefix: "foos_")
            XCTAssertEqual(foo.foo, 42)
            XCTAssertEqual(foo.bar, nil)
            XCTAssertEqual(foo.baz, "vapor")
        }
    }
}

package.path = "./syncest.koplugin/?.lua;./syncest.koplugin/?/init.lua;"
    .. package.path

local syncbooks = require("syncest_lib.syncbooks")

describe("cloud book inventory", function()
    local row = { hash = "abc123", format = "EPUB" }

    it("treats a missing or failed listing as absent", function()
        local state = syncbooks._inventory_state(row, nil)
        assert.is_false(state.book)
        assert.is_false(state.cover)
    end)

    it("requires the exact hash and expected extension", function()
        local state = syncbooks._inventory_state(row, {
            { text = "different.epub" },
            { text = "abc123.pdf" },
        })
        assert.is_false(state.book)
    end)

    it("detects book bytes and cover independently", function()
        local state = syncbooks._inventory_state(row, {
            { text = "abc123.epub" },
            { text = "cover.png" },
        })
        assert.is_true(state.book)
        assert.is_true(state.cover)
    end)
end)

describe("embedded catalog metadata", function()
    it("refreshes a filename-derived title", function()
        assert.is_true(syncbooks._metadata_needs_refresh({
            title = "Author - Real Title",
            author = "Author",
            metadata_json = '{"title":"Author - Real Title"}',
        }, {
            title = "Real Title",
            authors = "Author",
        }))
    end)

    it("does not rewrite matching complete metadata", function()
        assert.is_false(syncbooks._metadata_needs_refresh({
            title = "Real Title",
            author = "Author",
            metadata_json = '{"title":"Real Title"}',
        }, {
            title = "Real Title",
            authors = "Author",
        }))
    end)

    it("refreshes missing metadata even when names match", function()
        assert.is_true(syncbooks._metadata_needs_refresh({
            title = "Real Title",
            author = "Author",
            metadata_json = "{}",
        }, {
            title = "Real Title",
            authors = "Author",
        }))
    end)
end)

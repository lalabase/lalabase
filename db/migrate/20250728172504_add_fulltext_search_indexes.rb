# frozen_string_literal: true

# Adds PostgreSQL full-text search indexes for optimized ticket search
class AddFulltextSearchIndexes < ActiveRecord::Migration[8.0]
  def up
    # GIN index for ticket titles (highest priority)
    execute <<-SQL
      CREATE INDEX IF NOT EXISTS index_tickets_title_fts 
      ON tickets 
      USING gin(to_tsvector('german', title))
    SQL
    
    # GIN index for ActionText Rich Texts (for Ticket & Post content)
    execute <<-SQL
      CREATE INDEX IF NOT EXISTS index_action_text_rich_texts_body_fts 
      ON action_text_rich_texts 
      USING gin(to_tsvector('german', body))
      WHERE record_type IN ('Ticket', 'Post', 'Document')
    SQL
    
    # Composite index for frequent JOIN operations
    add_index :action_text_rich_texts, [:record_type, :record_id, :name], 
              name: 'index_action_texts_on_record_lookup',
              if_not_exists: true
    
    # Function-based index for combined search (optional, but performant)
    execute <<-SQL
      CREATE OR REPLACE FUNCTION ticket_search_vector(ticket_id bigint) 
      RETURNS tsvector AS $$
      DECLARE
        result tsvector;
      BEGIN
        SELECT 
          setweight(to_tsvector('german', COALESCE(t.title, '')), 'A') ||
          setweight(to_tsvector('german', COALESCE(tc.body, '')), 'B') ||
          setweight(to_tsvector('german', COALESCE(string_agg(pc.body, ' '), '')), 'C')
        INTO result
        FROM tickets t
        LEFT JOIN action_text_rich_texts tc ON tc.record_id = t.id 
          AND tc.record_type = 'Ticket' AND tc.name = 'content'
        LEFT JOIN posts p ON p.ticket_id = t.id
        LEFT JOIN action_text_rich_texts pc ON pc.record_id = p.id 
          AND pc.record_type = 'Post' AND pc.name = 'content'
        WHERE t.id = ticket_id
        GROUP BY t.id, t.title, tc.body;
        
        RETURN COALESCE(result, ''::tsvector);
      END;
      $$ LANGUAGE plpgsql IMMUTABLE;
    SQL
    
    # Optional: Materialized view for even better performance
    # Can be enabled later if needed
    # execute <<-SQL
    #   CREATE MATERIALIZED VIEW IF NOT EXISTS ticket_search_index AS
    #   SELECT 
    #     t.id as ticket_id,
    #     t.project_id,
    #     ticket_search_vector(t.id) as search_vector,
    #     t.created_at,
    #     t.updated_at
    #   FROM tickets t;
    #   
    #   CREATE INDEX IF NOT EXISTS idx_ticket_search_index_vector 
    #   ON ticket_search_index 
    #   USING gin(search_vector);
    #   
    #   CREATE INDEX IF NOT EXISTS idx_ticket_search_index_project 
    #   ON ticket_search_index (project_id);
    # SQL
  end
  
  def down
    # execute "DROP MATERIALIZED VIEW IF EXISTS ticket_search_index"
    execute "DROP FUNCTION IF EXISTS ticket_search_vector(bigint)"
    
    remove_index :action_text_rich_texts, name: 'index_action_texts_on_record_lookup', if_exists: true
    
    execute "DROP INDEX IF EXISTS index_action_text_rich_texts_body_fts"
    execute "DROP INDEX IF EXISTS index_tickets_title_fts"
  end
end
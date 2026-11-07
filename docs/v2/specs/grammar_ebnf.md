# Formal EBNF Grammar Specification (`v2/specs/grammar_ebnf.md`)

This specification defines the formal syntactic grammar of the VidSec Pipeline and Schema Definition Language using **ISO/IEC 14977 Extended Backus-Naur Form (EBNF)**.

The grammar is syntax-neutral: it defines the AST that both the **Compact DSL** and the **Declarative YAML** parser map into.

---

## 1. Lexical Rules

```ebnf
(* ===========================================================================
   1. Lexical Grammar (Tokens & Literals)
   =========================================================================== *)

letter               = "A" | "B" | "C" | "D" | "E" | "F" | "G" | "H" | "I"
                     | "J" | "K" | "L" | "M" | "N" | "O" | "P" | "Q" | "R"
                     | "S" | "T" | "U" | "V" | "W" | "X" | "Y" | "Z"
                     | "a" | "b" | "c" | "d" | "e" | "f" | "g" | "h" | "i"
                     | "j" | "k" | "l" | "m" | "n" | "o" | "p" | "q" | "r"
                     | "s" | "t" | "u" | "v" | "w" | "x" | "y" | "z" ;

digit                = "0" | "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" ;

hex_digit            = digit | "a" | "b" | "c" | "d" | "e" | "f"
                             | "A" | "B" | "C" | "D" | "E" | "F" ;

identifier           = ( letter | "_" ), { letter | digit | "_" } ;

qualified_name       = identifier, { ( "." | "/" ), identifier } ;

integer_literal      = [ "-" ], digit, { digit } ;

float_literal        = [ "-" ], digit, { digit }, ".", digit, { digit }
                     , [ ( "e" | "E" ), [ "+" | "-" ], digit, { digit } ] ;

boolean_literal      = "true" | "false" ;

string_literal       = '"', { ( [^"\\\n\r] | ( "\", ? any character ? ) ) }, '"'
                     | "'", { ( [^'\\\n\r] | ( "\", ? any character ? ) ) }, "'" ;

literal_value        = boolean_literal | float_literal | integer_literal | string_literal ;

comment              = "#", { ? any character except newline ? }, ? newline ? ;
```

---

## 2. High-Level Document Grammar

```ebnf
(* ===========================================================================
   2. Document Root & Global Sections
   =========================================================================== *)

PipelineDocument     = [ RuntimeSection ]
                     , [ NetworksSection ]
                     , [ DatasourcesSection ]
                     , [ ModulesSection ]
                     , PipelinesSection
                     , [ ComponentsSection ] ;

RuntimeSection       = "runtime", ":", "workers", ":", ( "auto" | integer_literal )
                     , [ "default_network", ":", NetworkId ] ;

NetworksSection      = "networks", ":", { NetworkDecl } ;

NetworkDecl          = NetworkId, ":"
                     , "driver", ":", NetworkDriver
                     , { NetworkOption } ;

NetworkId            = identifier ;
NetworkDriver        = "none" | "ingress_only" | "egress" | "sinkhole" ;
ProxyStrategy        = "round_robin" | "weighted" | "failover" | "least_latency" | "sticky_host" | "random" ;
NetworkOption        = identifier, ":", ( literal_value | qualified_name | ProxyStrategy ) ;

DatasourcesSection   = "datasources", ":" , { DatasourceDecl } ;

DatasourceDecl       = DatasourceId, ":"
                     , "type", ":", DatasourceType
                     , { DatasourceOption } ;

DatasourceId         = identifier ;
DatasourceType       = "memory" | "sqlite" | "file_store" | "amqp" ;
DatasourceOption     = identifier, ":", ( literal_value | qualified_name ) ;

ModulesSection       = "modules", ":" , { ModuleDecl } ;
ModuleDecl           = ModuleName, ":", "path", ":", string_literal ;
ModuleName           = identifier ;

ComponentsSection    = "components", ":" , "schemas", ":", { SchemaDecl } ;
```

---

## 3. Schemas and Type System Grammar

```ebnf
(* ===========================================================================
   3. Schema & Type Declarations
   =========================================================================== *)

SchemaDecl           = SchemaName, ":"
                     , "primary_key", ":", PrimaryKeySpec
                     , "columns", ":", { ColumnDecl }
                     , [ "indexes", ":", { IndexDecl } ] ;

SchemaName           = identifier ;

PrimaryKeySpec       = ColumnId | "[", ColumnId, { ",", ColumnId }, "]" ;

ColumnDecl           = ColumnId, ":", ( SimpleType | ComplexColumnSpec ) ;

ColumnId             = identifier ;

SimpleType           = ScalarType | CollectionType ;

ScalarType           = "int64" | "float64" | "bool" | "text" | "blob" ;

CollectionType       = ( "array" | "set" ), "<", SimpleType, ">"
                     | "map", "<", ScalarType, ",", SimpleType, ">" ;

ComplexColumnSpec    = "{", ColumnAttribute, { ",", ColumnAttribute }, "}" ;

ColumnAttribute      = "type", ":", SimpleType
                     | "pk", ":", boolean_literal
                     | "nullable", ":", boolean_literal
                     | "default", ":", literal_value
                     | "ref", ":", ForeignKeyRef
                     | "defer_fk", ":", boolean_literal ;

ForeignKeyRef        = SchemaName, ".", ColumnId ;

IndexDecl            = "columns", ":", "[", ColumnId, { ",", ColumnId }, "]"
                     , [ ",", "unique", ":", boolean_literal ]
                     , [ ",", "build", ":", ( "immediate" | "deferred" ) ] ;
```

---

## 4. Pipeline Execution & Step Grammar

```ebnf
(* ===========================================================================
   4. Pipeline Execution & Dataflow Step Grammar
   =========================================================================== *)

PipelinesSection     = "pipelines", ":", { PipelineDecl } ;

PipelineDecl         = PipelineId, ":", "steps", ":", { Step } ;

PipelineId           = identifier ;

Step                 = TaskStep | RouterStep ;

(* --- Task Step: Invokes a pure computational task with optional stream algebra --- *)
TaskStep             = [ StepId, ":" ]
                     , [ StreamPipeline, "->" ]
                     , TaskTarget
                     , [ "(", [ ParameterList ], ")" ]
                     , [ "@net", "(", NetworkId, { ",", NetworkId }, ")" ]
                     , [ "where", FilterPredicate ]
                     , [ "concurrency", ":", ConcurrencySpec ]
                     , [ "=>", OutputDispatchList ] ;

ConcurrencySpec      = "1" | "auto" | "max" | integer_literal ;

StepId               = identifier ;

TaskTarget           = ModuleName, "/", TaskName ;
TaskName             = identifier ;

ParameterList        = ParameterAssignment, { ",", ParameterAssignment } ;
ParameterAssignment  = ParamName, "=", InboundExpr ;
ParamName            = identifier ;

(* --- Inbound Expressions: Scalars, Stream References, or Stream Algebra --- *)
InboundExpr          = StreamAlgebraExpr | Expression ;

StreamAlgebraExpr    = MergeExpr | ZipExpr | JoinExpr ;

MergeExpr            = "merge", "(", StreamRef, { ",", StreamRef }, ")" ;

ZipExpr              = "zip", "(", StreamRef, ",", StreamRef, ")" ;

JoinExpr             = "join", "(", StreamRef, ",", StreamRef, ",", "on", "=", Expression, ")" ;

StreamRef            = StepId, ".", ChannelName ;

(* --- Chained Inbound Stream Modifiers (Compact Pipe Notation) --- *)
StreamPipeline       = ( StreamRef | StreamAlgebraExpr ), { "->", StreamModifier } ;

StreamModifier       = "filter", "(", Expression, ")"
                     | "take_while", "(", Expression, ")"
                     | "buffer", "(", "size", "=", integer_literal, ")" ;

FilterPredicate      = Expression ;

(* --- Output Dispatch: Routes task outputs to datasources --- *)
OutputDispatchList   = OutputChannel, { ",", OutputChannel } ;

OutputChannel        = ChannelName
                     , [ "from", ChannelSource ]
                     , [ "[", SchemaReference, "]" ]
                     , ">>", DatasourceId
                     , [ "filter", FilterPredicate ] ;

ChannelName          = identifier ;
ChannelSource        = identifier ;
SchemaReference      = qualified_name | InlineSchemaSpec ;

InlineSchemaSpec     = "{", InlineFieldSpec, { ",", InlineFieldSpec }, "}" ;

InlineFieldSpec      = FieldName, ":", ( SimpleType | EnrichedFieldSpec ) ;
FieldName            = identifier ;

EnrichedFieldSpec    = "{", FieldAttribute, { ",", FieldAttribute }, "}" ;
FieldAttribute       = "type", ":", SimpleType
                     | "from", ":", ( FieldName | Expression )
                     | "default", ":", literal_value
                     | "rule", ":", Expression ;

(* --- Router Step: Evaluates conditions without side effects --- *)
RouterStep           = "branch", "{" , { RouterCase } , [ "default", "->", PipelineId ] , "}" ;

RouterCase           = "when", Expression, "->", PipelineId ;
```

---

## 5. Expression Grammar

```ebnf
(* ===========================================================================
   6. Expression Calculus (Routers, Derived Fields, Filters)
   =========================================================================== *)

Expression           = LogicalOrExpr ;

LogicalOrExpr        = LogicalAndExpr, { "or", LogicalAndExpr } ;

LogicalAndExpr       = EqualityExpr, { "and", EqualityExpr } ;

EqualityExpr         = RelationalExpr, [ ( "==" | "!=" ), RelationalExpr ] ;

RelationalExpr       = AdditiveExpr, [ ( "<" | "<=" | ">" | ">=" | "IN" ), AdditiveExpr ] ;

AdditiveExpr         = MultiplicativeExpr, { ( "+" | "-" ), MultiplicativeExpr } ;

MultiplicativeExpr   = UnaryExpr, { ( "*" | "/" | "%" ), UnaryExpr } ;

UnaryExpr            = [ "not" | "-" ], PrimaryExpr ;

PrimaryExpr          = literal_value
                     | qualified_name
                     | FunctionCall
                     | "(", Expression, ")" ;

FunctionCall         = FunctionName, "(", [ ArgumentList ], ")" ;
FunctionName         = identifier ;
ArgumentList         = Expression, { ",", Expression } ;
```

---

## 6. Concrete Parsing Equivalences

### Example A: Standalone Scalar Task Step
```text
stage0: analyzer/probe_file(strict=true, min_size=8) => [file_triage] >> audit_db, coord >> pipeline_memory
```

#### Corresponding AST Mapping:
```json
{
  "type": "TaskStep",
  "id": "stage0",
  "stream_source": null,
  "operator": null,
  "target": { "module": "analyzer", "task": "probe_file" },
  "params": {
    "strict": { "type": "bool", "value": true },
    "min_size": { "type": "int64", "value": 8 }
  },
  "outputs": [
    {
      "channel": "triage_record",
      "schema_ref": "file_triage",
      "datasource": "audit_db"
    },
    {
      "channel": "coord",
      "schema_ref": null,
      "datasource": "pipeline_memory"
    }
  ]
}
```

---

### Example B: Automatic Lifting with Declarative `where` Filter
```text
audit: analyzer/check_padding(box=lower_mp4.regions) where box.role == "padding" => [audit_findings] >> audit_db
```

#### Corresponding AST Mapping:
```json
{
  "type": "TaskStep",
  "id": "audit",
  "target": { "module": "analyzer", "task": "check_padding" },
  "params": {
    "box": {
      "type": "StreamRef",
      "source": "lower_mp4.regions"
    }
  },
  "where": "box.role == 'padding'",
  "outputs": [
    {
      "channel": "findings",
      "schema_ref": "audit_findings",
      "datasource": "audit_db"
    }
  ]
}
```

---

### Example C: Multi-Stream Algebra (`merge`) with Collection Processing
```text
coalesce: analyzer/coalesce_slack(regions=merge(mp4_ir.slack, mkv_ir.slack)) where length >= 64 => [audit_findings] >> audit_db
```

#### Corresponding AST Mapping:
```json
{
  "type": "TaskStep",
  "id": "coalesce",
  "target": { "module": "analyzer", "task": "coalesce_slack" },
  "params": {
    "regions": {
      "type": "MergeExpr",
      "sources": [
        "mp4_ir.slack",
        "mkv_ir.slack"
      ]
    }
  },
  "where": "length >= 64",
  "outputs": [
    {
      "channel": "findings",
      "schema_ref": "audit_findings",
      "datasource": "audit_db"
    }
  ]
}
```

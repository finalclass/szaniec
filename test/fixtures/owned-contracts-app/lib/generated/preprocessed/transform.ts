const source = Deno.readTextFileSync(Deno.args[0]);
console.log(source.replace("Placeholder", "App_contract.Common"));

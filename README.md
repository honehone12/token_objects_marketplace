# token_objects_marketplace
marketplace for token objects written in move.  

this implementation has two major problems.  

1. owner can transfer object while it is still listed.
1. user has to update their "store"(resource that hold object info in owner's address) manually. (or should we simply depend on indexer or some new way will be introduced on native level?? now i'm not sure at this point.)    


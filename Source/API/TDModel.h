//
//  TDModel.h
//  TouchDB
//
//  Created by Jens Alfke on 8/26/11.
//  Copyright (c) 2011 Couchbase, Inc. All rights reserved.
//

#import "MYDynamicObject.h"
#import "TDDocument.h"
@class TDAttachment, TDDatabase, TDDocument;


/** Generic model class for TouchDB documents.
    There's a 1::1 mapping between these and TDDocuments; call +modelForDocument: to get (or create) a model object for a document, and .document to get the document of a model.
    You should subclass this and declare properties in the subclass's @@interface. As with NSManagedObject, you don't need to implement their accessor methods or declare instance variables; simply note them as '@@dynamic' in the class @@implementation. The property value will automatically be fetched from or stored to the document, using the same name.
    Supported scalar types are bool, char, short, int, double. These map to JSON numbers, except 'bool' which maps to JSON 'true' and 'false'. (Use bool instead of BOOL.)
    Supported object types are NSString, NSNumber, NSData, NSDate, NSArray, NSDictionary. (NSData and NSDate are not native JSON; they will be automatically converted to/from strings in base64 and ISO date formats, respectively.)
    Additionally, a property's type can be a pointer to a TDModel subclass. This provides references between model objects. The raw property value in the document must be a string whose value is interpreted as a document ID. */
@interface TDModel : MYDynamicObject <TDDocumentModel>

/** Returns the TDModel associated with a TDDocument, or creates & assigns one if necessary.
    If the TDDocument already has an associated model, it's returned. Otherwise a new one is instantiated.
    If you call this on TDModel itself, it'll delegate to the TDModelFactory to decide what class to instantiate; this lets you map different classes to different "type" property values, for instance.
    If you call this method on a TDModel subclass, it will always instantiate an instance of that class; e.g. [MyWidgetModel modelForDocument: doc] always creates a MyWidgetModel. */
+ (id) modelForDocument: (TDDocument*)document;

/** Creates a new "untitled" model with a new unsaved document.
    The document won't be written to the database until -save is called. */
- (id) initWithNewDocumentInDatabase: (TDDatabase*)database;

/** Creates a new "untitled" model object with no document or database at all yet.
    Setting its .database property will cause it to create a TDDocument.
    (This method is mostly here so that NSController objects can create TDModels.) */
- (id) init;

/** The document this item is associated with. Will be nil if it's new and unsaved. */
@property (readonly, retain) TDDocument* document;

/** The database the item's document belongs to.
    Setting this property will assign the item to a database, creating a document.
    Setting it to nil will delete its document from its database. */
@property (retain) TDDatabase* database;

/** Is this model new, never before saved? */
@property (readonly) bool isNew;

#pragma mark - SAVING:

/** Writes any changes to a new revision of the document.
    Returns YES without doing anything, if no changes have been made. */
- (BOOL) save: (NSError**)outError;

/** Should changes be saved back to the database automatically?
    Defaults to NO, requiring you to call -save manually. */
@property (nonatomic) bool autosaves;

/** How long to wait after the first change before auto-saving, if autosaves is true.
    Default value is 0.0; subclasses can override this to add a delay. */
@property (readonly) NSTimeInterval autosaveDelay;

/** Does this model have unsaved changes? */
@property (readonly) bool needsSave;

/** The document's current properties (including unsaved changes) in externalized JSON format.
    This is what will be written to the TDDocument when the model is saved. */
- (NSDictionary*) propertiesToSave;

/** Deletes the document from the database. 
    You can still use the model object afterwards, but it will refer to the deleted revision. */
- (BOOL) deleteDocument: (NSError**)outError;

/** The time interval since the document was last changed externally (e.g. by a "pull" replication.
    This value can be used to highlight recently-changed objects in the UI. */
@property (readonly) NSTimeInterval timeSinceExternallyChanged;

/** Bulk-saves changes to multiple model objects (which must all be in the same database).
    The saves are performed in one transaction, for efficiency.
    Any unchanged models in the array are ignored.
    See also: -[TDDatabase saveAllModels:].
    @param models  An array of TDModel objects, which must all be in the same database.
    @return  A RESTOperation that saves all changes, or nil if none of the models need saving. */
+ (BOOL) saveModels: (NSArray*)models error: (NSError**)outError;

/** Resets the timeSinceExternallyChanged property to zero. */
- (void) markExternallyChanged;

#pragma mark - PROPERTIES & ATTACHMENTS:

/** Gets a property by name.
    You can use this for document properties that you haven't added @@property declarations for. */
- (id) getValueOfProperty: (NSString*)property;

/** Sets a property by name.
    You can use this for document properties that you haven't added @@property declarations for. */
- (BOOL) setValue: (id)value ofProperty: (NSString*)property;


/** The names of all attachments (array of strings).
    This reflects unsaved changes made by creating or deleting attachments. */
@property (readonly) NSArray* attachmentNames;

/** Looks up the attachment with the given name (without fetching its contents). */
- (TDAttachment*) attachmentNamed: (NSString*)name;

/** Creates or updates an attachment (in memory).
    The attachment data will be written to the database at the same time as property changes are saved.
    @param attachment  A newly-created TDAttachment (not yet associated with any revision)
    @param name  The attachment name. */
- (void) addAttachment: (TDAttachment*)attachment named: (NSString*)name;

/** Deletes (in memory) any existing attachment with the given name.
    The attachment will be deleted from the database at the same time as property changes are saved. */
- (void) removeAttachmentNamed: (NSString*)name;


#pragma mark - PROTECTED (FOR SUBCLASSES TO OVERRIDE)

/** Designated initializer. Do not call directly except from subclass initializers; to create a new instance call +modelForDocument: instead.
    @param document  The document. Nil if this is created new (-init was called). */
- (id) initWithDocument: (TDDocument*)document;

/** The document ID to use when creating a new document.
    Default is nil, which means to assign no ID (the server will assign one). */
- (NSString*) idForNewDocumentInDatabase: (TDDatabase*)db;

/** Called when the model's properties are reloaded from the document.
    This happens both when initialized from a document, and after an external change. */
- (void) didLoadFromDocument;

/** Returns the database in which to look up the document ID of a model-valued property.
    Defaults to the same database as the receiver's document. You should override this if a document property contains the ID of a document in a different database. */
- (TDDatabase*) databaseForModelProperty: (NSString*)propertyName;

@end



/** TDDatabase methods for use with TDModel. */
@interface TDDatabase (TDModel)

/** All TDModels associated with this database whose needsSave is true. */
@property (readonly) NSArray* unsavedModels;

/** Saves changes to all TDModels associated with this database whose needsSave is true. */
- (BOOL) saveAllModels: (NSError**)outError;

/** Immediately runs any pending autosaves for all TDModels associated with this database.
    (On iOS, this will automatically be called when the application is about to quit or go into the
    background. On Mac OS it is NOT called automatically.) */
- (BOOL) autosaveAllModels: (NSError**)outError;

@end